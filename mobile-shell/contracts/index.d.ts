export const CONTRACT_VERSION: 1;
export const DELIVERY_PACKAGE_FORMAT: "iris.mobile-shell.package+json";
export const DELIVERY_PACKAGE_LIMITS: Readonly<{
  maxFiles: 256;
  maxDecodedBytes: number;
  maxSingleFileBytes: number;
}>;

export type MobileShellCapability =
  | "web.storage"
  | "web.network.same-origin"
  | "web.navigation.external"
  | "web.media.camera"
  | "web.media.export"
  | "web.media.microphone"
  | "web.media.photo-picker"
  | "native.share"
  | "native.haptics"
  | "native.camera"
  | "native.microphone"
  | "native.photo-library";

export const KNOWN_CAPABILITIES: readonly MobileShellCapability[];
export const KNOWN_CHANGE_KINDS: readonly MobileShellRevisionChangeKind[];
export const CHANGE_LIMITS: Readonly<{ maxTitleChars: number; maxChanges: number }>;

export interface MobileShellManifestV1 {
  kind: "iris.mobile-shell.manifest";
  version: 1;
  appId: string;
  projectId: string;
  displayName: string;
  runtime: { type: "web"; entrypoint: string; minShellVersion: string };
  capabilities: MobileShellCapability[];
  data: { namespace: string; updatePolicy: "preserve" };
}

export interface MobileShellRevisionFileV1 {
  path: string;
  sha256: `sha256:${string}`;
  bytes: number;
  mediaType: string;
}

/** Contract v1.1 (owner-decided 2026-09-28): the plain-words feature title(s)
 * a revision carries, for the phone Features page. Optional -- a revision
 * without it reads "Update from <date>" on the phone. */
export type MobileShellRevisionChangeKind = "added" | "removed";
export interface MobileShellRevisionChangeV1 {
  title: string;
  kind: MobileShellRevisionChangeKind;
  target: `rev-sha256:${string}` | null;
}

export interface MobileShellRevisionV1 {
  kind: "iris.mobile-shell.revision";
  version: 1;
  appId: string;
  projectId: string;
  revisionId: `rev-sha256:${string}`;
  baseRevisionId: `rev-sha256:${string}` | null;
  manifestHash: `sha256:${string}`;
  contentHash: `sha256:${string}`;
  createdAt: string;
  manifest: MobileShellManifestV1;
  files: MobileShellRevisionFileV1[];
  changes?: MobileShellRevisionChangeV1[];
}

export interface MobileShellEditRequestV1 {
  kind: "iris.mobile-shell.edit-request";
  version: 1;
  requestId: string;
  nonce: string;
  appId: string;
  projectId: string;
  baseRevisionId: `rev-sha256:${string}`;
  requestedAt: string;
  intent: { type: "feature" | "bugfix"; text: string };
}

export interface MobileShellDeliveryApprovalV1 {
  kind: "iris.mobile-shell.delivery-approval";
  version: 1;
  approvalId: string;
  requestId: string | null;
  requestNonce: string | null;
  appId: string;
  projectId: string;
  baseRevisionId: `rev-sha256:${string}` | null;
  approvedRevisionId: `rev-sha256:${string}`;
  approvedContentHash: `sha256:${string}`;
  approvedAt: string;
}

export interface MobileShellDeliveryEnvelopeV1 {
  kind: "iris.mobile-shell.delivery-envelope";
  version: 1;
  envelopeId: string;
  deliveryNonce: string;
  approvalId: string;
  appId: string;
  projectId: string;
  baseRevisionId: `rev-sha256:${string}` | null;
  revisionId: `rev-sha256:${string}`;
  contentHash: `sha256:${string}`;
  issuedAt: string;
  revision: MobileShellRevisionV1;
}

export interface MobileShellDeliveryPackageFileV1 {
  path: string;
  mediaType: string;
  contentBase64: string;
}

export interface MobileShellDeliveryPackageV1 {
  format: "iris.mobile-shell.package+json";
  approval: MobileShellDeliveryApprovalV1;
  envelope: MobileShellDeliveryEnvelopeV1;
  files: MobileShellDeliveryPackageFileV1[];
}

export interface VerifiedMobileShellDeliveryPackageV1 {
  approval: MobileShellDeliveryApprovalV1;
  envelope: MobileShellDeliveryEnvelopeV1;
  revision: MobileShellRevisionV1;
  manifest: MobileShellManifestV1;
  files: Array<{ path: string; mediaType: string; bytes: Uint8Array }>;
}

export type ValidationResult<T> = { ok: true; value: T } | { ok: false; errors: string[] };

export function isSafePackagePath(value: unknown): boolean;
export function revisionIdForContentHash(contentHash: unknown): string | null;
export function validateManifestV1(value: unknown): ValidationResult<MobileShellManifestV1>;
export function validateRevisionV1(value: unknown): ValidationResult<MobileShellRevisionV1>;
export function validateEditRequestV1(
  value: unknown,
  options?: { currentRevisionId?: string; usedNonces?: Set<string> },
): ValidationResult<MobileShellEditRequestV1>;
export function validateDeliveryApprovalV1(
  value: unknown,
  options?: { editRequest?: MobileShellEditRequestV1 },
): ValidationResult<MobileShellDeliveryApprovalV1>;
export function validateDeliveryEnvelopeV1(
  value: unknown,
  options?: {
    approval?: MobileShellDeliveryApprovalV1;
    currentRevisionId?: string | null;
    usedDeliveryNonces?: Set<string>;
  },
): ValidationResult<MobileShellDeliveryEnvelopeV1>;
export function validateDeliveryPackageV1(value: unknown): ValidationResult<MobileShellDeliveryPackageV1>;
export function validateRevisionChangesV1(
  changes: unknown,
): ValidationResult<MobileShellRevisionChangeV1[] | undefined>;

export function evaluateShellCompatibility(
  manifest: unknown,
  shell: { version?: string; supportedCapabilities?: string[] },
): { ok: boolean; reasons: string[]; unsupportedCapabilities: string[] };

export function compareSemver(left: unknown, right: unknown): -1 | 0 | 1 | null;
export const FIRST_SHELL_VERSION_ACCEPTING_CHANGES: string;

// --- App Store Guideline 4.7 metadata (m3-guideline47) -------------------

export const APP_STORE_METADATA_KIND: "iris.mobile-shell.app-store-metadata";
export const APP_STORE_METADATA_VERSION: 1;
export type AppStoreAgeRating = 4 | 9 | 13 | 16 | 18;
export const KNOWN_AGE_RATINGS: readonly AppStoreAgeRating[];
export const APP_STORE_METADATA_LIMITS: Readonly<{
  maxPrivacySummaryChars: 600;
  maxContactValueChars: 320;
  maxURLChars: 2048;
}>;

export interface AppStoreContactMethodV1 {
  kind: "email" | "url";
  value: string;
}

export interface AppStoreMetadataV1 {
  kind: "iris.mobile-shell.app-store-metadata";
  version: 1;
  ageRating: AppStoreAgeRating;
  privacySummary: string;
  privacyPolicyUrl: string;
  supportContact: AppStoreContactMethodV1;
  reportContact: AppStoreContactMethodV1;
}

export function validateAppStoreMetadataV1(value: unknown): ValidationResult<AppStoreMetadataV1>;

// --- Catalog index v2 (m3-catalog-contract-scale) -------------------------

export const CATALOG_INDEX_V2_VERSION: 2;
export const CATALOG_APP_PAGE_V1_VERSION: 1;
export const CATALOG_CATEGORIES_V1_VERSION: 1;

export const CATALOG_V2_LIMITS: Readonly<{
  appsPerPage: 250;
  /** Budget for catalogIndexEntryDataBytes(entry): the row's values, not its fixed field names. */
  maxAppEntryBytes: 200;
  maxCategories: 24;
  indexClientCapBytes: number;
  /** Largest byteCount an index row may advertise (48 MiB, the raw package limit). */
  maxPackageBytes: number;
  maxScreenshotsPerApp: 6;
  maxScreenshotBytes: number;
  maxIconBytes: number;
  maxDescriptionChars: 4000;
  maxSummaryChars: 80;
  maxWhatsNewChars: 2000;
  maxPermissionLabelChars: 120;
  maxCategoryNameChars: 60;
}>;

export type CatalogBadge = "new" | "updated";
export const KNOWN_CATALOG_BADGES: readonly CatalogBadge[];

export interface CatalogIndexAppPlacementV1 {
  featured: boolean;
  sponsored: boolean;
  label: string;
}

export interface CatalogIndexAppV1 {
  slug: string;
  name: string;
  summary: string;
  categoryIds: number[];
  /** 16 lowercase hex characters: a truncated, non-cryptographic change-detection token, not an install-integrity digest. */
  iconHash: string;
  iconURL: string;
  /** Download size in bytes; must equal the app page's mobileShell.byteCount. */
  byteCount: number;
  ageRating: AppStoreAgeRating;
  /** Calendar date of the last update, YYYY-MM-DD (UTC). */
  updatedAt: string;
  badges: CatalogBadge[];
  /** null means no special placement (the common case). */
  placement: CatalogIndexAppPlacementV1 | null;
  /** Optional (RC-05). Who made the app; 1 to 80 plain characters. Absent means Publik. */
  publisher?: string;
}

export const CATALOG_PUBLISHER_MAX_CHARS: 80;
export function isCatalogPublisherName(value: unknown): boolean;

export interface CatalogIndexV2 {
  version: 2;
  generatedAt: string;
  page: number;
  pageCount: number;
  apps: CatalogIndexAppV1[];
}

export function validateCatalogIndexV2(value: unknown): ValidationResult<CatalogIndexV2>;

/** UTF-8 bytes of the row's values written as one JSON array in schema order; Infinity for a non-row. */
export function catalogIndexEntryDataBytes(entry: unknown): number;

export interface CatalogCategoryV1 {
  id: number;
  name: string;
  order: number;
  appCount: number;
}

export interface CatalogCategoriesV1 {
  categories: CatalogCategoryV1[];
}

export function validateCatalogCategoriesV1(value: unknown): ValidationResult<CatalogCategoriesV1>;

export interface CatalogAppPageMobileShellV1 {
  version: 1;
  platform: "ios";
  packageFormat: "iris.mobile-shell.package+json";
  downloadUrl: string;
  mediaType: "application/json";
  byteCount: number;
  packageSha256: `sha256:${string}`;
  appId: string;
  projectId: string;
  baseRevisionId: `rev-sha256:${string}` | null;
  revisionId: `rev-sha256:${string}`;
  contentHash: `sha256:${string}`;
  appStoreMetadata: AppStoreMetadataV1 | null;
}

export interface CatalogAppPageScreenshotV1 {
  url: string;
  bytes: number;
}

export interface CatalogAppPagePermissionV1 {
  capability: MobileShellCapability;
  label: string;
}

export interface CatalogAppPageV1 {
  mobileShell: CatalogAppPageMobileShellV1;
  description: string;
  screenshots: CatalogAppPageScreenshotV1[];
  permissions: CatalogAppPagePermissionV1[];
  privacySummary: string;
  supportURL: string;
  whatsNew: string | null;
}

export function validateCatalogAppPageV1(value: unknown): ValidationResult<CatalogAppPageV1>;

/** Index row and its app page must agree on byteCount and (when present) the reviewed age rating. */
export function validateCatalogIndexEntryMatchesAppPage(
  entry: CatalogIndexAppV1,
  appPage: CatalogAppPageV1,
): ValidationResult<{ entry: CatalogIndexAppV1; appPage: CatalogAppPageV1 }>;

export function canonicalJSONString(value: unknown): string;
export function sha256Digest(
  value: string | Uint8Array | ArrayBuffer | ArrayBufferView,
  options?: { subtle?: SubtleCrypto },
): Promise<`sha256:${string}`>;

export function createRevisionIdentity(
  input: {
    appId: string;
    projectId: string;
    baseRevisionId: `rev-sha256:${string}` | null;
    manifest: MobileShellManifestV1;
    files: MobileShellRevisionFileV1[];
  },
  options?: { subtle?: SubtleCrypto },
): Promise<{ manifestHash: `sha256:${string}`; contentHash: `sha256:${string}`; revisionId: `rev-sha256:${string}` }>;

export function verifyRevisionIntegrity(
  revision: MobileShellRevisionV1,
  fileContents: Map<string, string | Uint8Array | ArrayBuffer | ArrayBufferView> | Record<string, string | Uint8Array | ArrayBuffer | ArrayBufferView>,
  options?: { subtle?: SubtleCrypto },
): Promise<ValidationResult<MobileShellRevisionV1>>;

export function verifyDeliveryPackageV1(
  value: unknown,
  options?: {
    currentRevisionId?: string | null;
    usedDeliveryNonces?: Set<string>;
    editRequest?: MobileShellEditRequestV1;
    subtle?: SubtleCrypto;
  },
): Promise<ValidationResult<VerifiedMobileShellDeliveryPackageV1>>;
