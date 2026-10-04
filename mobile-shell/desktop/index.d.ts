import type {
  MobileShellDeliveryApprovalV1,
  MobileShellEditRequestV1,
  MobileShellManifestV1,
  MobileShellRevisionV1,
} from "../contracts/index.js";

export interface DesktopRegisteredProjectV1 {
  kind: "iris.mobile-shell.desktop-project";
  version: 1;
  appId: string;
  projectId: string;
  appSlug: string;
  provenance: {
    kind: "guideSourceClone";
    clonePath: string;
    pinnedCommit: string;
    canonicalRepo: string | null;
  };
}

export interface DesktopPackageReviewV1 {
  kind: "iris.mobile-shell.desktop-package-review";
  version: 1;
  reviewedAt: string;
  baseRevisionId: `rev-sha256:${string}` | null;
  manifest: MobileShellManifestV1;
  files: Array<{ path: string; mediaType: string }>;
}

export interface DesktopStagedRevisionV1 {
  kind: "iris.mobile-shell.desktop-stage";
  version: 1;
  stageId: string;
  stagedAt: string;
  appId: string;
  projectId: string;
  baseRevisionId: `rev-sha256:${string}` | null;
  revision: MobileShellRevisionV1;
  files: Array<{ path: string; mediaType: string; contentBase64: string }>;
}

export interface DesktopApprovedStageV1 {
  kind: "iris.mobile-shell.desktop-approved-stage";
  version: 1;
  stage: DesktopStagedRevisionV1;
  editRequest: MobileShellEditRequestV1 | null;
  approval: MobileShellDeliveryApprovalV1;
}

export interface DeliveryPackageV1 {
  format: "iris.mobile-shell.package+json";
  approval: MobileShellDeliveryApprovalV1;
  envelope: import("../contracts/index.js").MobileShellDeliveryEnvelopeV1;
  files: Array<{ path: string; mediaType: string; contentBase64: string }>;
}

export interface LiveProvenanceReceipt {
  ok: true;
  provenanceKind: "guideSourceClone";
  appId: string;
  projectId: string;
  currentRevisionId: `rev-sha256:${string}`;
}

export type ProvenanceCheck = (input: {
  registration: DesktopRegisteredProjectV1;
  currentRevisionId: `rev-sha256:${string}`;
}) => Promise<LiveProvenanceReceipt> | LiveProvenanceReceipt;

export type ExistingIrisEditCallback<TResult = unknown> = (input: {
  request: MobileShellEditRequestV1;
  registration: DesktopRegisteredProjectV1;
}) => Promise<TResult> | TResult;

export class ReceiptReplayError extends Error {
  code: "replayed_request" | "replayed_delivery";
}

export class DurableReceiptStore {
  constructor(filePath: string);
  readonly filePath: string;
  read(): Promise<unknown>;
  hasAcceptedRequest(request: MobileShellEditRequestV1): Promise<boolean>;
  hasRequestNonce(nonce: string): Promise<boolean>;
  hasDeliveryNonce(nonce: string): Promise<boolean>;
  usedDeliveryNonces(): Promise<Set<string>>;
  claimRequest(request: MobileShellEditRequestV1, acceptedAt?: string): Promise<unknown>;
  claimDelivery(envelope: import("../contracts/index.js").MobileShellDeliveryEnvelopeV1): Promise<unknown>;
}

export function validateRegisteredProject(value: unknown): DesktopRegisteredProjectV1;
export function validatePackageReview(
  value: unknown,
  registration: DesktopRegisteredProjectV1,
  currentRevisionId: `rev-sha256:${string}` | null,
): DesktopPackageReviewV1;

export function stageRevision(input: {
  registration: DesktopRegisteredProjectV1;
  buildOutputRoot: string;
  review: DesktopPackageReviewV1;
  currentRevisionId: `rev-sha256:${string}` | null;
  createdAt?: string;
}): Promise<DesktopStagedRevisionV1>;

export function handleEditRequest<TResult = unknown>(input: {
  registration: DesktopRegisteredProjectV1;
  request: MobileShellEditRequestV1;
  currentRevisionId: `rev-sha256:${string}`;
  receiptStore?: DurableReceiptStore;
  provenanceCheck?: ProvenanceCheck;
  editCallback?: ExistingIrisEditCallback<TResult>;
}): Promise<
  | { status: "unsupported"; code: "edit_engine_unwired" | "provenance_check_unwired"; message: string }
  | { status: "accepted"; request: MobileShellEditRequestV1; receipt: unknown; editResult: TResult }
>;

export function approveStagedRevision(input: {
  registration: DesktopRegisteredProjectV1;
  stage: DesktopStagedRevisionV1;
  currentRevisionId: `rev-sha256:${string}` | null;
  receiptStore?: DurableReceiptStore;
  editRequest?: MobileShellEditRequestV1 | null;
  localApproval: true;
  approvedAt?: string;
}): Promise<DesktopApprovedStageV1>;

export function createDeliveryPackage(input: {
  registration: DesktopRegisteredProjectV1;
  approvedStage: DesktopApprovedStageV1;
  currentRevisionId: `rev-sha256:${string}` | null;
  receiptStore: DurableReceiptStore;
  deliveryNonce?: string;
  issuedAt?: string;
}): Promise<DeliveryPackageV1>;

