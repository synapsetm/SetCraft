# Distribution — SetCraft

Anleitung, um SetCraft auszuliefern: als notarisiertes,
automatisch-updatebares macOS-DMG **außerhalb des App Stores** (Abschnitte
1–7) und als iOS-Build über TestFlight (Abschnitt 8). Das Repo enthält die
fertigen Build-Pfade in `scripts/release.sh` und `scripts/release-ios.sh`;
diese Doku erklärt, was du einmalig einrichten musst, bevor die Skripte
durchlaufen.

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
   → neues Passwort `SetCraft Notary` erzeugen.
2. Profil im Keychain ablegen (passiert einmalig):
   ```sh
   xcrun notarytool store-credentials AC_SETCRAFT \
     --apple-id "deine-apple-id@example.com" \
     --team-id "D75S77JA58" \
     --password "abcd-efgh-ijkl-mnop"
   ```
3. Smoke-Test:
   ```sh
   xcrun notarytool history --keychain-profile AC_SETCRAFT
   ```
   Sollte ohne Fehler eine (leere) Liste zurückgeben.

Der Profilname `AC_SETCRAFT` ist im Release-Skript der Default. Anderen Namen
kannst du via `NOTARY_PROFILE=eigener_name ./scripts/release.sh` benutzen.

---

## 3) Sparkle einrichten (Auto-Update)

Sparkle erwartet einen **EdDSA-Signaturschlüssel** und einen statisch
gehosteten Appcast.

### 3.1) Schlüsselpaar erzeugen

```sh
# Sparkle wurde via Swift Package eingebunden. Das CLI-Tooling liegt im
# DerivedData-Cache, nachdem Xcode das Paket einmal aufgelöst hat.
# Achtung: der bin-Ordner liegt unter .../artifacts/sparkle/Sparkle/bin —
# also nach 'bin' suchen, nicht nach 'Sparkle'.
SPARKLE_BIN_DIR="$(find ~/Library/Developer/Xcode/DerivedData \
    -type d -name bin -path '*/artifacts/*/Sparkle/bin' 2>/dev/null | head -1)"

# Ohne Cache: einmal `xcodebuild -resolvePackageDependencies` laufen lassen.

"$SPARKLE_BIN_DIR/generate_keys"
```

`generate_keys` legt den **Private-Key automatisch im Login-Keychain** ab
(Sparkle wird ihn beim Signieren wiederfinden) und gibt den Public-Key als
Base64-String auf stdout aus.

### 3.2) Public-Key in `SetCraft/Info.plist` eintragen

```xml
<key>SUPublicEDKey</key>
<string>HIER_DER_AUSGEGEBENE_PUBLIC_KEY</string>
```

### 3.3) Appcast-URL festlegen

`SetCraft/Info.plist` zeigt mit `SUFeedURL` auf den statisch gehosteten Appcast:

```xml
<key>SUFeedURL</key>
<string>https://synapsetm.github.io/SetCraft/appcast.xml</string>
```

Diese URL bedient GitHub Pages aus dem `docs/`-Ordner des Hauptrepos. Aktiviere
Pages einmalig unter *Repo → Settings → Pages → Source: Deploy from a branch →
Branch `main` / `/docs`*.

Die DMG selbst landet **nicht** in `docs/`, sondern als Asset eines
**GitHub-Releases** (`https://github.com/synapsetm/SetCraft/releases/download/<tag>/<dmg>`).
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

- `MARKETING_VERSION` (z. B. `1.3`) und `CURRENT_PROJECT_VERSION` (Buildnummer,
  monoton steigend) in der Xcode-Projektkonfiguration anheben. Im pbxproj steht
  jeder Wert **viermal** — Mac und iOS, je Debug und Release.
- **Die Build-Nummern laufen seit 1.3-16 bewusst auseinander** (Stand
  2026-09-24: Mac 18, iOS 37), weil iOS-only-Fixes eigene TestFlight-Builds
  bekommen, während für den Mac kein Release ansteht. Anzuheben ist also nur
  das Target, das released wird. Die iOS-Configs sind die mit
  `PRODUCT_BUNDLE_IDENTIFIER = ch.buehler.beat.SetCraft.iOS`; alternativ
  `BUILD_NUMBER=<n> ./scripts/release-ios.sh`, das überschreibt den Wert.
  `MARKETING_VERSION` bleibt gemeinsam.
- **Beide Release-Skripte prüfen die Lokalisierung** — nach dem Archive, vor
  dem Export. Ein fehlender deutscher String bricht ab, bevor etwas
  notarisiert oder hochgeladen wird. Bewusst übergehen: `SKIP_L10N_CHECK=1`.
- Das Skript zieht beide Werte automatisch und benennt das DMG entsprechend
  (`SetCraft-1.1-4.dmg`).
- **Den Versions-Commit vorher pushen.** Der Vorflug-Check in `release.sh`
  bricht bei ungepushten Commits ab — sonst hinge das GitHub-Release an
  einem Stand, den sonst niemand sieht.

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
├── SetCraft.xcarchive
├── export/SetCraft.app          ← stapled, kann auch einzeln verschickt werden
└── dist/
    ├── SetCraft-1.0-1.dmg       ← parallel an GitHub-Release hochgeladen
    └── appcast.xml            ← Quelle für docs/appcast.xml
```

Veröffentlicht wird automatisch:
- `docs/appcast.xml` → `https://synapsetm.github.io/SetCraft/appcast.xml`
- DMG → `https://github.com/synapsetm/SetCraft/releases/download/v<version>-<build>/SetCraft-<version>-<build>.dmg`

---

## 6) GPL-Hinweis (Hintergrund)

SetCraft linkt **aubio** (GPL) und **libKeyFinder** (GPL). Sobald du die
fertige App an Dritte weitergibst, musst du nach GPL §3 entweder:

- den Quellcode mitliefern, oder
- ein schriftliches Angebot beilegen, dass du den Quellcode auf Anfrage
  herausgibst.

Beides ist trivial erfüllt, solange das GitHub-Repo öffentlich ist und in
einer `README.md`-Notiz beim Download verlinkt wird. Die `.xcframework`s in
`SetCraftCore/Vendor/` sind aus reproduzierbaren Build-Skripten gebaut, deren
Quelle ebenfalls im Repo liegt.

---

## 7) Erstinstallation testen

Nach dem ersten Release auf einem **frischen** Mac (oder einem zweiten
User-Account, der die App noch nie gesehen hat) prüfen:

```sh
# DMG mounten, App in /Applications ziehen, dann:
spctl --assess --type execute --verbose=4 /Applications/SetCraft.app
```

Sollte `accepted, source=Notarized Developer ID` ausgeben. Wenn nicht:
Stapling-Ticket fehlt oder Notarisierung nicht durchgelaufen — Log über
`xcrun notarytool log <submission-id> --keychain-profile AC_SETCRAFT` anfordern.

---

## 8) iOS — TestFlight

Der iOS-Weg läuft **nicht** über GitHub-Release-Assets, sondern über
App Store Connect / TestFlight.

```sh
./scripts/release-ios.sh
```

Das Skript archiviert, exportiert das IPA und lädt per `altool` hoch.
Die Build-Nummer kommt aus dem pbxproj und lässt sich per
`BUILD_NUMBER=… ./scripts/release-ios.sh` überschreiben.

**Credentials** liegen ausserhalb des Repos und werden automatisch gelesen:

| Datei | Inhalt |
|---|---|
| `~/.appstoreconnect/setcraft.env` (0600) | `ASC_API_KEY_ID`, `ASC_API_ISSUER_ID` |
| `~/.appstoreconnect/private_keys/AuthKey_<KEY>.p8` (0600) | der API-Key selbst |

ENV-Variablen überschreiben die Datei, falls nötig.

### 8.1) Distribution-Signatur einrichten (einmalig)

Vor dem ersten Release einmal:

```sh
./scripts/asc-setup-signing.sh
```

Das Skript legt an, was der Export braucht, und überspringt, was schon da ist:

1. ein **Apple-Distribution-Zertifikat** (CSR lokal erzeugt, über die ASC-API
   signiert, als PKCS#12 in den Login-Schlüsselbund importiert),
2. ein **App-Store-Provisioning-Profil** „SetCraft iOS App Store", das genau
   dieses Zertifikat enthält, abgelegt unter
   `~/Library/Developer/Xcode/UserData/Provisioning Profiles/`.

Ist-Zustand ansehen, ohne etwas anzulegen: `./scripts/asc-setup-signing.sh --list`.

Der private Schlüssel liegt in `~/.appstoreconnect/certificates/` (0600).
**Mitsichern** — ohne ihn ist das Zertifikat auf einem neuen Rechner wertlos
und muss neu angelegt werden. Apple erlaubt zwei Distribution-Zertifikate pro
Account; das Skript legt deshalb kein zweites an, sondern bricht ab.

Zertifikat und Profil laufen nach einem Jahr ab (aktuell bis **2027-09-18**).
Danach das Skript erneut laufen lassen.

#### Warum nicht einfach automatisches Signieren?

Weil es reproduzierbar scheitert:

```
error: exportArchive Cloud signing permission error
  You haven't been given access to cloud-managed distribution certificates.
```

Die Ursache ist nicht Sprunghaftigkeit, sondern eine fehlende Identität:
`security find-identity -v -p codesigning` zeigte nur „Apple Development" und
„Developer ID Application" — Letzteres ist der Mac-Weg am Store vorbei und für
iOS nutzlos. Ohne lokale Distribution-Identität weicht `xcodebuild` auf
Cloud-Signing aus, und dafür trägt der ASC-API-Key die falsche Rolle: nötig
wäre Admin oder App Manager.

Interessant dabei: ein **reguläres** Distribution-Zertifikat darf der Key sehr
wohl anlegen — die Rollenprüfung greift nur bei den *cloud-managed*. Deshalb
kommt `asc-setup-signing.sh` ohne Rollenänderung aus.

`ExportOptions-iOS.plist` signiert entsprechend **manuell**
(`signingStyle: manual`, `signingCertificate: Apple Distribution`,
`provisioningProfiles` → „SetCraft iOS App Store"). Damit fragt der Export das
Cloud-Signing gar nicht erst, und der Umweg über den Xcode Organizer entfällt.

Verifiziert am 2026-09-18 mit Build 1.3-16: `** EXPORT SUCCEEDED **`, IPA
signiert mit `Apple Distribution: Beat Buehler (D75S77JA58)`.

### 8.1b) Alte Builds ablaufen lassen

```sh
scripts/asc-expire-builds.sh              # alles ausser dem neuesten VALID
scripts/asc-expire-builds.sh --dry-run    # nur zeigen
```

Apple raeumt TestFlight nicht zuverlaessig auf: am 2026-09-20 standen Build 21
und Build 19 gleichzeitig aktiv, waehrend 20 und 18 abgelaufen waren. Wer dann
in TestFlight auf „Installieren" tippt, testet womoeglich einen Stand, dessen
Fehler laengst behoben sind.

**Sicherheitsregel:** behalten wird immer der neueste Build mit
`processingState == VALID`. Ist der neueste noch in Verarbeitung, bricht das
Skript ab — sonst bliebe fuer die Dauer der Verarbeitung nichts Installierbares
auf dem Geraet. Also: erst `asc-status.sh`, dann ablaufen lassen.

Der schreibende Zugriff laeuft ueber `asc_api_patch` in `scripts/asc-auth.sh`
(vorher konnte der Helfer nur GET).

### 8.2) Was Apple sonst erwartet

- `ITSAppUsesNonExemptEncryption=false` im `SetCraft-iOS-Info.plist` —
  spart den Compliance-Dialog vor jedem Build.
- AppIcon 1024×1024 **ohne** Alpha-Kanal. Der Mac-Icon-Master ist RGBA und
  muss vor der Übernahme auf RGB geflattet werden.
- `CURRENT_PROJECT_VERSION` muss pro Upload eindeutig sein — Apple zählt
  auch abgelehnte Builds mit.

---

## 9) Troubleshooting-Häppchen

- **„Developer-ID-Identity nicht auflösbar"**: Zertifikat nicht im Login-
  Keychain oder noch nicht verifiziert. Login-Keychain entsperren, Cert neu
  doppelklicken.
- **Notary-Fehler `Invalid signature`**: Sandbox + Hardened Runtime müssen
  beide aktiv sein, und alle eingebetteten Frameworks (auch Sparkle, auch die
  xcframeworks) müssen Developer-ID-signiert sein. `xcodebuild archive`
  übernimmt das normalerweise selbst — falls nicht, hilft ein Cleanbuild
  (`rm -rf build/ ~/Library/Developer/Xcode/DerivedData/SetCraft-*`).
- **Sparkle meint „Update fehlerhaft"**: `SUPublicEDKey` in der installierten
  App passt nicht zum Private-Key, mit dem das DMG signiert wurde. Public-
  Key in `Info.plist` ersetzen und neu releasen.
- **`errSecInternalComponent` beim iOS-`exportArchive`**: Signieren scheitert,
  ohne dass am Code etwas falsch waere. Ursache ist der Schluesselbund-Dialog,
  der nach dem Zugriff auf den privaten Schluessel des Distribution-Zertifikats
  fragt — wird er abgebrochen, scheitert der Export mit genau diesem Code.
  Im Dialog „**Immer erlauben**" waehlen; „Erlauben" beantwortet nur diesen
  einen Lauf und die Rueckfrage kommt beim naechsten Release wieder.
  Hochgeladen wird dabei nichts, die Build-Nummer bleibt frei.
- **Lokalisierungs-Gate meldet „keine .stringsdata gefunden"**: das Skript
  sucht seit 2026-09-19 auch unter `ArchiveIntermediates/`. Kommt die Meldung
  trotzdem, wurde das Target noch nie gebaut oder ein `clean` des anderen
  Targets hat die Daten weggeraeumt — dann einmal bauen und erneut pruefen.
  Der Befund ist bewusst blockierend: „nicht pruefbar" darf nicht als „sauber"
  durchgehen.
- **„The application can't be opened"** auf einem Test-Mac, der zuvor das
  unsignierte Dev-Build kannte: Quarantäne-Attribut hängt noch dran,
  `xattr -dr com.apple.quarantine /Applications/SetCraft.app` räumt auf.
