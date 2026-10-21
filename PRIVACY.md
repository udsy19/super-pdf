# Privacy

Super PDF works on your Mac. Your documents are opened, changed, converted, signed and checked on this Mac and never
leave it unless you send them somewhere yourself (Share, Mail, AirDrop, a signing package you send). There is no
account, no telemetry, no crash reporting, no analytics and no remote settings. Super PDF has no AI and ships no model.

## The only network connections (features §3.5)

| Connection | When | What is sent |
|---|---|---|
| `api.github.com`, `github.com` | Update checks, a minute after launch and every few hours (Settings › Privacy turns them off); Super PDF › Check for Updates… when you choose it; downloading an update | The app's version in the user agent |
| The timestamp server you name | Only if you turn on "Add a trusted timestamp" in Settings › Signatures and sign with a certificate | A fingerprint (hash) of the signed file, never the file |

"Get LibreOffice" and "Get Pages" open those apps' download pages in your browser or the App Store; Super PDF itself
downloads nothing for them. Everything else works with Wi-Fi off.

## What is stored, and where

| Data | Where |
|---|---|
| Your files and the files tools make | Next to the originals (or where you choose); originals are never overwritten without asking |
| Saved signatures (pictures), encrypted with a key kept in your login Keychain | `~/Library/Application Support/Super PDF/Signatures/` |
| Signing certificates and their private keys | Your login Keychain |
| People whose certificates you trust | Super PDF's settings |
| Signature requests: the packages you sent, the copies that came back, the audit record | `~/Library/Application Support/Super PDF/Requests/<request>/` |
| Routines ("Do this to many files") | `~/Library/Application Support/Super PDF/Routines/` |
| LibreOffice's private profile, when Super PDF runs your installed LibreOffice | `~/Library/Application Support/Super PDF/Helpers/lo-profile/` |
| The update checker's bookkeeping | `~/Library/Application Support/Super PDF/update.json` |
| Where you were in a document (page, zoom, sidebar) | The file's extended attribute `com.udsy.superpdf.viewstate`, never inside the PDF |
| Settings, recent files, recently used tools | `~/Library/Preferences/com.udsy.superpdf.plist` |
| Scratch files while a tool runs | The system's temporary folder, removed when the tool is done |

## What it asks to use

| Permission | Why |
|---|---|
| Camera | Scanning a page from a photo, and holding up a signature to save it |
| Microphone | Recording a voice note on a page |
| Contacts | Filling forms from your own card, your name on notes, and the people you ask to sign |
| Automation | Asking Word, Excel, PowerPoint, Pages, Numbers or Keynote to export a file you convert ("… will open briefly") |
| Desktop, Documents, Downloads | Saving the files tools make next to the originals |

Each is asked the first time it is needed, and only then.

## Removing everything

Delete the app, `~/Library/Application Support/Super PDF/`, `~/Library/Preferences/com.udsy.superpdf.plist`, the
"Save to Super PDF" item in `~/Library/PDF Services/` if you added it, and, in Keychain Access, the items named
`com.udsy.superpdf` and your Super PDF signing certificates.
