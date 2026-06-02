# Distribution — Setify

Anleitung, um Setify als notarisiertes, automatisch-updatebares macOS-DMG
**außerhalb des App Stores** auszuliefern. Das Repo enthält bereits den
fertigen Build-Pfad in `scripts/release.sh`; diese Doku erklärt, was du einmalig
einrichten musst, bevor das Skript durchläuft.

> Voraussetzung: Apple Developer Program-Mitgliedschaft (kostenpflichtig), weil
> nur damit ein „Developer ID Application"-Zertifikat sowie Notarisierung
> möglich sind.

---

## 1) Developer-ID-Zertifikat erzeugen

1. https://developer.apple.com/account → **Certificates, IDs & Profiles**.
2. **Certificates → +** → „Developer ID Application" → CSR aus Keychain
   Access erzeugen (Menü → **Certificate Assistant → Request a Certificate
   from a Certificate Authority…**, Save to disk).
3. Heruntergeladene `.cer` doppelklicken → landet im Login-Keychain.
4. Prüfen mit:
   ```sh
   security find-identity -v -p codesigning
   ```
   Ein Eintrag mit `Developer ID Application: <Name> (D75S77JA58)` muss
   erscheinen.

Optional: für signierte Installer-Pakete (`.pkg`) zusätzlich
„Developer ID Installer". Für DMG-Distribution nicht nötig.

---

## 2) Notarytool-Keychain-Profil anlegen

Notarytool akzeptiert entweder Apple-ID + App-spezifisches Passwort **oder**
einen App-Store-Connect-API-Key. Variante mit App-spezifischem Passwort:

1. https://appleid.apple.com → **Sign-In and Security → App-Specific Passwords**
   → neues Passwort `Setify Notary` erzeugen.
2. Profil im Keychain ablegen (passiert einmalig):
   ```sh
   xcrun notarytool store-credentials AC_SETIFY \
     --apple-id "deine-apple-id@example.com" \
     --team-id "D75S77JA58" \
     --password "abcd-efgh-ijkl-mnop"
   ```
3. Smoke-Test:
   ```sh
   xcrun notarytool history --keychain-profile AC_SETIFY
   ```
   Sollte ohne Fehler eine (leere) Liste zurückgeben.

Der Profilname `AC_SETIFY` ist im Release-Skript der Default. Anderen Namen
kannst du via `NOTARY_PROFILE=eigener_name ./scripts/release.sh` benutzen.

---

## 3) Sparkle einrichten (Auto-Update)

Sparkle erwartet einen **EdDSA-Signaturschlüssel** und einen statisch
gehosteten Appcast.

### 3.1) Schlüsselpaar erzeugen

```sh
# Sparkle wurde via Swift Package eingebunden. Das CLI-Tooling liegt im
# DerivedData-Cache, nachdem Xcode das Paket einmal aufgelöst hat.
SPARKLE_BIN_DIR="$(find ~/Library/Developer/Xcode/DerivedData \
    -type d -name 'Sparkle' -path '*/artifacts/*/bin' 2>/dev/null | head -1)"

# Ohne Cache: einmal `xcodebuild -resolvePackageDependencies` laufen lassen.

"$SPARKLE_BIN_DIR/generate_keys"
```

`generate_keys` legt den **Private-Key automatisch im Login-Keychain** ab
(Sparkle wird ihn beim Signieren wiederfinden) und gibt den Public-Key als
Base64-String auf stdout aus.

### 3.2) Public-Key in `Setify/Info.plist` eintragen

```xml
<key>SUPublicEDKey</key>
<string>HIER_DER_AUSGEGEBENE_PUBLIC_KEY</string>
```

### 3.3) Appcast-URL festlegen

`Setify/Info.plist` zeigt mit `SUFeedURL` auf den statisch gehosteten Appcast:

```xml
<key>SUFeedURL</key>
<string>https://synapsetm.github.io/Setify/appcast.xml</string>
```

Diese URL bedient GitHub Pages aus dem `docs/`-Ordner des Hauptrepos. Aktiviere
Pages einmalig unter *Repo → Settings → Pages → Source: Deploy from a branch →
Branch `main` / `/docs`*.

Die DMG selbst landet **nicht** in `docs/`, sondern als Asset eines
**GitHub-Releases** (`https://github.com/synapsetm/Setify/releases/download/<tag>/<dmg>`).
Das Release-Skript erzeugt den Tag, lädt die DMG hoch und schreibt im
`enclosure`-Tag des Appcasts die korrekte Download-URL.

### 3.4) GitHub-CLI authentifizieren

Das Release-Skript benutzt `gh` für Release-Upload und das Pushen des
Appcasts. Einmalig:

```sh
brew install gh        # falls nicht da
gh auth login          # GitHub-Account, Scope 'repo' aktivieren
```

### 3.5) Spätere Updates

Pro Release brauchst du nur `MARKETING_VERSION` + `CURRENT_PROJECT_VERSION`
anheben, committen, pushen — und dann:

```sh
./scripts/release.sh
```

Das Skript erledigt von da an alles automatisch (Build → Notarize → DMG →
GitHub-Release-Upload → Appcast-Generierung → Pages-Commit + Push).

---

## 4) Version bumpen

Vor jedem Release:

- `MARKETING_VERSION` (z. B. `1.1`) und `CURRENT_PROJECT_VERSION` (Buildnummer,
  monoton steigend, z. B. `4`) in der Xcode-Projektkonfiguration anheben.
- Das Skript zieht beide Werte automatisch und benennt das DMG entsprechend
  (`Setify-1.1-4.dmg`).

---

## 5) Release ausführen

```sh
./scripts/release.sh
```

Das Skript ruft in dieser Reihenfolge:

1. `xcodebuild archive`
2. `xcodebuild -exportArchive` (Developer-ID, Hardened Runtime)
3. `notarytool submit` für die `.app` (warten) + `stapler staple`
4. `hdiutil create` für das DMG + `codesign`
5. `notarytool submit` für das DMG (warten) + `stapler staple`
6. `gh release create v<version>-<build>` mit der DMG als Asset
7. `generate_appcast --download-url-prefix …` (Sparkle, EdDSA-Signatur aus Keychain)
8. `docs/appcast.xml` aktualisieren, committen, `git push origin <branch>`
9. `spctl --assess` für DMG und App (informativer Selbsttest)

Lokale Outputs unter `build/release/` (gitignored):

```
build/release/
├── Setify.xcarchive
├── export/Setify.app          ← stapled, kann auch einzeln verschickt werden
└── dist/
    ├── Setify-1.0-1.dmg       ← parallel an GitHub-Release hochgeladen
    └── appcast.xml            ← Quelle für docs/appcast.xml
```

Veröffentlicht wird automatisch:
- `docs/appcast.xml` → `https://synapsetm.github.io/Setify/appcast.xml`
- DMG → `https://github.com/synapsetm/Setify/releases/download/v<version>-<build>/Setify-<version>-<build>.dmg`

---

## 6) GPL-Hinweis (Hintergrund)

Setify linkt **aubio** (GPL) und **libKeyFinder** (GPL). Sobald du die
fertige App an Dritte weitergibst, musst du nach GPL §3 entweder:

- den Quellcode mitliefern, oder
- ein schriftliches Angebot beilegen, dass du den Quellcode auf Anfrage
  herausgibst.

Beides ist trivial erfüllt, solange das GitHub-Repo öffentlich ist und in
einer `README.md`-Notiz beim Download verlinkt wird. Die `.xcframework`s in
`SetifyCore/Vendor/` sind aus reproduzierbaren Build-Skripten gebaut, deren
Quelle ebenfalls im Repo liegt.

---

## 7) Erstinstallation testen

Nach dem ersten Release auf einem **frischen** Mac (oder einem zweiten
User-Account, der die App noch nie gesehen hat) prüfen:

```sh
# DMG mounten, App in /Applications ziehen, dann:
spctl --assess --type execute --verbose=4 /Applications/Setify.app
```

Sollte `accepted, source=Notarized Developer ID` ausgeben. Wenn nicht:
Stapling-Ticket fehlt oder Notarisierung nicht durchgelaufen — Log über
`xcrun notarytool log <submission-id> --keychain-profile AC_SETIFY` anfordern.

---

## 8) Troubleshooting-Häppchen

- **„Developer-ID-Identity nicht auflösbar"**: Zertifikat nicht im Login-
  Keychain oder noch nicht verifiziert. Login-Keychain entsperren, Cert neu
  doppelklicken.
- **Notary-Fehler `Invalid signature`**: Sandbox + Hardened Runtime müssen
  beide aktiv sein, und alle eingebetteten Frameworks (auch Sparkle, auch die
  xcframeworks) müssen Developer-ID-signiert sein. `xcodebuild archive`
  übernimmt das normalerweise selbst — falls nicht, hilft ein Cleanbuild
  (`rm -rf build/ ~/Library/Developer/Xcode/DerivedData/Setify-*`).
- **Sparkle meint „Update fehlerhaft"**: `SUPublicEDKey` in der installierten
  App passt nicht zum Private-Key, mit dem das DMG signiert wurde. Public-
  Key in `Info.plist` ersetzen und neu releasen.
- **„The application can't be opened"** auf einem Test-Mac, der zuvor das
  unsignierte Dev-Build kannte: Quarantäne-Attribut hängt noch dran,
  `xattr -dr com.apple.quarantine /Applications/Setify.app` räumt auf.
