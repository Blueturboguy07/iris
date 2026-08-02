# Troubleshooting

## App Won't Start

**Symptom:** Nothing happens when you launch Clicky, or it crashes immediately.

- Make sure you're on Windows 10 (1903+) or Windows 11
- Try running from source to see error output: `npm run dev`
- Check if another instance is already running (look in Task Manager for `electron.exe`)

## Tray Icon Not Visible

**Symptom:** App is running but you can't see the icon.

- Click the `^` arrow in the taskbar (bottom-right) to expand the system tray
- Go to **Settings > Personalization > Taskbar > Other system tray icons** and enable Clicky
- If the icon looks blank, the app is running but the icon may not render on some display scaling settings

## "Error: Claude API error (401)"

**Symptom:** You send a message and get a 401 error.

- Your Anthropic API key is invalid or expired
- Click the gear icon in the chat title bar to open the key setup
- Re-enter your key and save
- Make sure there are no extra spaces or line breaks in the key
- Verify the key works: visit [console.anthropic.com](https://console.anthropic.com/) and check it's active

## "Error: Claude API error (429)"

**Symptom:** Rate limit exceeded.

- You've hit Anthropic's rate limit for your plan
- Wait a minute and try again
- Check your usage at [console.anthropic.com](https://console.anthropic.com/)
- Consider upgrading your Anthropic plan for higher limits

## "Error: Claude API error (400)"

**Symptom:** Bad request error.

- The screenshot may be too large — this shouldn't happen normally as Clicky caps images at 1280px
- Try a simpler question without triggering a screenshot (if supported)
- If persistent, report the issue with the full error text

## Screenshots Not Working

**Symptom:** Claude responds but doesn't seem to see your screen.

- On Windows 11, screen capture may require the app to not be running in a restricted sandbox
- Make sure Clicky has screen capture permissions (usually auto-granted on Windows)
- Some DRM-protected content (Netflix, Disney+, etc.) will appear black in screenshots — this is by design

## Voice Input Not Working

**Symptom:** Push-to-talk doesn't capture audio.

- Check that you have an AssemblyAI key configured (Settings > AssemblyAI API Key)
- Make sure your microphone is working (test in Windows Settings > Sound)
- The global hotkey (`Ctrl+Alt+Space`) may conflict with another app — change it in Settings
- Try running Clicky as administrator if the global hotkey isn't registering

## TTS Not Speaking

**Symptom:** Responses appear as text but no audio plays.

- Check that **Spoken responses** is enabled in Settings
- If using ElevenLabs, verify your API key is valid and you have credits remaining
- If using Windows SAPI, make sure you have a speech voice installed:
  - Go to **Windows Settings > Time & Language > Speech**
  - Ensure at least one voice is downloaded
- Check your system audio output (volume, correct device selected)

## Overlay Cursor Not Appearing

**Symptom:** Claude mentions pointing at something but no blue cursor appears.

- The overlay window needs to be running — it starts automatically with the app
- If you have multiple monitors, the cursor might be pointing at a different screen
- Some full-screen apps may render on top of the overlay
- Try restarting Clicky

## High Memory Usage

**Symptom:** Clicky is using a lot of RAM.

- Electron apps typically use 100-200MB — this is normal
- If memory climbs over time, restart the app (Quit from tray, relaunch)
- Long conversation histories are kept in memory — they're cleared on restart

## Proxy Connection Issues

**Symptom:** "Failed to fetch" or network errors when using a proxy.

- Verify the proxy URL is correct and accessible (try opening it in a browser)
- Check that the proxy has the required API keys configured as secrets
- Make sure your network/firewall allows outbound HTTPS to the proxy URL
- Try disabling the proxy and using direct API keys to isolate the issue

## Still Stuck?

- [Open an issue](https://github.com/tekram/clicky-windows/issues) on GitHub with:
  - Your Windows version
  - Steps to reproduce
  - Error messages (if any)
  - Whether you're using BYOK or proxy mode
