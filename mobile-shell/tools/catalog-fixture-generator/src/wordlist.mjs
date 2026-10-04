// Ordinary English words used to build realistic-looking (but fake) app
// names, deterministically, so fixture catalogs do not all look like
// "App 1", "App 2", ... Two lists are combined ("Focus" + "Timer"); the
// combination is picked by index from the seeded RNG so names are varied
// but reproducible.

export const NAME_ADJECTIVES = [
  "Focus", "Quiet", "Bright", "Swift", "Daily", "Simple", "Clear", "Tiny",
  "Warm", "Steady", "Fresh", "Calm", "Sharp", "Easy", "Cozy", "Prime",
  "Open", "Local", "Modern", "Handy", "True", "Kind", "Wild", "Solid",
  "Gentle", "Rapid", "Honest", "Quick", "Loyal", "Vivid",
];

export const NAME_NOUNS = [
  "Timer", "Notes", "Recipes", "Journal", "Tracker", "Planner", "Budget",
  "Habits", "Sketch", "Playlist", "Reader", "Mail", "Tasks", "Camera",
  "Map", "Weather", "Chat", "Wallet", "Fitness", "Sleep", "Coach", "Diary",
  "Garden", "Kitchen", "Studio", "Board", "Ledger", "Compass", "Lantern",
  "Trail", "Meter", "Vault", "Canvas", "Signal", "Harbor", "Meadow",
];

export const CATEGORY_NAMES = [
  "Productivity", "Health & Fitness", "Finance", "Education",
  "Photo & Video", "Games", "Utilities", "Social", "Music", "Reading",
  "Food & Drink", "Travel", "Shopping", "News", "Weather", "Kids",
  "Developer Tools", "Design", "Writing", "Reference", "Lifestyle",
  "Business", "Sports", "Medical",
];

export const KNOWN_CAPABILITY_LABELS = {
  "native.camera": "Use the camera",
  "native.haptics": "Vibrate for alerts",
  "native.microphone": "Use the microphone",
  "native.photo-library": "Read and save photos",
  "native.share": "Share to other apps",
  "web.media.camera": "Take photos and video",
  "web.media.export": "Save files you create",
  "web.media.microphone": "Record audio",
  "web.media.photo-picker": "Choose photos to use",
  "web.navigation.external": "Open links outside the app",
  "web.network.same-origin": "Connect to its own server",
  "web.storage": "Remember your data on this device",
};

export const DESCRIPTION_SENTENCES = [
  "Built for people who want less clutter and more done.",
  "Works offline and syncs quietly when you are back online.",
  "Designed around one clear task, not a dozen half-finished ones.",
  "Keeps your data on this device unless you choose to share it.",
  "Made for a quick daily check-in, not a long session.",
  "Small enough to open on a break, useful enough to keep.",
];

// One-line store summaries. "{adj}" is the name's first word and "{noun}"
// its second, lowercased. Plain language on purpose: these are what a
// non-technical person reads on a store card.
export const SUMMARY_TEMPLATES = [
  "Keep your {noun} simple and close at hand",
  "A calm {noun} for busy days",
  "Track, plan and share your {noun} in one place",
  "The quickest way to check your {noun}",
  "{adj} tools for everyday {noun}",
  "Works offline and keeps your {noun} private",
  "Your {noun}, sorted in seconds",
  "Made for people who love a good {noun}",
  "Set up your {noun} once, then forget about it",
  "A {noun} that stays out of your way",
];
