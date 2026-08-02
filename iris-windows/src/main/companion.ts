import { BrowserWindow } from "electron";
import { ScreenCapture, ScreenshotResult, cropScreenshotRegion } from "./screenshot";
import { SettingsStore } from "./settings";
import { AccountSession } from "./account-session";
import { ClaudeService, ConversationEntry } from "../services/claude";
import {
  AssistantTransportFailure,
  selectTransport,
  userFacingMessage,
} from "../services/assistant-transport";
import {
  PointTag,
  parsePointTags,
  resolvePointForOverlay,
  stripPointTags,
} from "../services/coordinates";

/**
 * companion.ts
 *
 * The pipeline: typed message -> screenshot -> model -> optional two-pass point
 * refinement -> overlay. Mirrors `CompanionManager` in the macOS app.
 *
 * The refinement pass and the three coordinate spaces are inherited from
 * upstream and are the part most likely to break; all of the arithmetic now
 * lives in `services/coordinates.ts` where it is covered by tests.
 */

const MAX_CONVERSATION_TURNS = 10;

/**
 * ~300 IMAGE-space pixels: small enough to disambiguate neighbouring similar
 * elements, large enough to keep context. At native DPI this is a much sharper
 * patch than cropping the downsampled pass-1 image would give.
 */
const REFINEMENT_CROP_SIZE_IN_IMAGE_SPACE = 300;

export class CompanionManager {
  private readonly settings: SettingsStore;
  private readonly account: AccountSession;
  private readonly screenCapture = new ScreenCapture();
  private conversationHistory: ConversationEntry[] = [];
  private overlayWindows: BrowserWindow[];

  constructor(settings: SettingsStore, account: AccountSession, overlayWindows: BrowserWindow[]) {
    this.settings = settings;
    this.account = account;
    this.overlayWindows = overlayWindows;
  }

  setOverlayWindows(overlayWindows: BrowserWindow[]): void {
    this.overlayWindows = overlayWindows;
  }

  private broadcastStage(stage: string, label: string): void {
    for (const window of BrowserWindow.getAllWindows()) {
      if (!window.isDestroyed()) {
        window.webContents.send("companion:stage", { stage, label });
      }
    }
  }

  /**
   * Builds the model client for the current credentials. Which tier is in play
   * is decided fresh on every message, because the user can sign in, sign out,
   * or paste a key between one message and the next.
   */
  private createClaudeService(): ClaudeService {
    const transport = selectTransport({
      isSignedIn: this.account.isSignedIn(),
      publikBaseUrl: this.settings.get("publikBaseUrl"),
      storedAnthropicApiKey: this.settings.getAnthropicApiKey(),
      currentAccessToken: () => this.account.currentAccessToken(),
    });
    return new ClaudeService({ transport, model: this.settings.get("claudeModel") });
  }

  /**
   * Process one typed message. Returns the text to show the user, with POINT
   * tags already stripped.
   */
  async processQuery(userMessage: string): Promise<string> {
    try {
      this.broadcastStage("capturing", "Reading screen...");
      const screenshots = await this.screenCapture.captureAllScreens();
      const cursorPosition = this.screenCapture.getCursorPosition();

      this.conversationHistory.push({ role: "user", content: userMessage });

      this.broadcastStage("querying", "Analyzing...");
      const claude = this.createClaudeService();
      const response = await claude.query({
        userMessage,
        screenshots,
        cursorPosition,
        conversationHistory: this.conversationHistory,
      });

      this.conversationHistory.push({ role: "assistant", content: response.text });
      if (this.conversationHistory.length > MAX_CONVERSATION_TURNS * 2) {
        this.conversationHistory = this.conversationHistory.slice(-MAX_CONVERSATION_TURNS * 2);
      }

      const pointTagsInImageSpace = parsePointTags(response.text);
      if (pointTagsInImageSpace.length > 0) {
        this.broadcastStage("refining", "Refining points...");
        const displayPoints = await this.resolvePointTags(
          pointTagsInImageSpace,
          screenshots,
          claude
        );
        this.sendPointsToOverlays(displayPoints);
      }

      return stripPointTags(response.text);
    } catch (error) {
      if (error instanceof AssistantTransportFailure) {
        // A transport failure is a sentence the user can act on, never a status
        // code and never the server's own body.
        throw new Error(userFacingMessage(error.detail));
      }
      throw error instanceof Error ? error : new Error(String(error));
    } finally {
      this.broadcastStage("done", "");
    }
  }

  /**
   * Second pass, then the IMAGE -> DISPLAY conversion. Refinement failures fall
   * back to the first-pass estimate rather than dropping the point entirely.
   */
  private async resolvePointTags(
    tags: PointTag[],
    screenshots: ScreenshotResult[],
    claude: ClaudeService
  ): Promise<PointTag[]> {
    return Promise.all(
      tags.map(async (tag) => {
        const shot = screenshots[tag.screen] ?? screenshots[0];
        if (!shot) return tag;

        try {
          const crop = cropScreenshotRegion(
            shot,
            { x: tag.x, y: tag.y },
            REFINEMENT_CROP_SIZE_IN_IMAGE_SPACE
          );
          const refined = await claude.refinePoint({
            cropBase64: crop.data,
            cropWidth: crop.cropSize.width,
            cropHeight: crop.cropSize.height,
            label: tag.label,
          });

          const displayPoint = resolvePointForOverlay({
            imagePoint: { x: tag.x, y: tag.y },
            imageDimensions: shot.imageDimensions,
            displayBounds: shot.bounds,
            refinement: refined ? { pointInCropSpace: refined, cropPlan: crop.plan } : undefined,
          });
          return { ...tag, x: displayPoint.x, y: displayPoint.y };
        } catch {
          // Refinement is an optimisation; losing it must not lose the point.
          const displayPoint = resolvePointForOverlay({
            imagePoint: { x: tag.x, y: tag.y },
            imageDimensions: shot.imageDimensions,
            displayBounds: shot.bounds,
          });
          return { ...tag, x: displayPoint.x, y: displayPoint.y };
        }
      })
    );
  }

  /** Route each tag to the overlay for its own display. */
  private sendPointsToOverlays(tags: PointTag[]): void {
    if (tags.length === 0 || this.overlayWindows.length === 0) return;

    const tagsByScreen = new Map<number, PointTag[]>();
    for (const tag of tags) {
      const list = tagsByScreen.get(tag.screen) ?? [];
      list.push(tag);
      tagsByScreen.set(tag.screen, list);
    }

    for (const [screenIndex, tagsForScreen] of tagsByScreen) {
      if (screenIndex < 0 || screenIndex >= this.overlayWindows.length) {
        console.warn(
          `[iris] POINT tag screen=${screenIndex} is out of range ` +
            `(have ${this.overlayWindows.length} overlay windows); routing to the primary display.`
        );
      }
      const window = this.overlayWindows[screenIndex] ?? this.overlayWindows[0];
      if (window && !window.isDestroyed()) {
        window.webContents.send("overlay:point", tagsForScreen);
      }
    }
  }

  clearHistory(): void {
    this.conversationHistory = [];
  }
}
