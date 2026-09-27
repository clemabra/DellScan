# Dell Scan

Native macOS-App (SwiftUI) zum Scannen mit Multifunktionsgeräten, die **WSD-Scan**
(Web Services for Devices / WS-Scan) sprechen – entstanden für den
**Dell C2665dnf Color MFP**, dessen Scanfunktion von aktuellen macOS-Versionen
nicht mehr unterstützt wird.

macOS kann von Haus aus nur eSCL/AirScan. Viele ältere Netzwerk-MFPs (Dell,
Xerox, Brother, Kyocera, …) können aber nur WSD. Diese App implementiert das
Protokoll direkt – ohne Treiber.

> Status: frühe Version. Protokoll gegen einen WSD-Simulator getestet,
> Test am echten C2665dnf steht noch aus.

## Funktionen

- Automatische Suche per WS-Discovery im lokalen Netz, alternativ direkte IP-Eingabe
- Vorlagenglas, Einzug einseitig, Einzug beidseitig (falls vom Gerät unterstützt)
- Farbe / Graustufen / Schwarzweiß, Auflösung und Papiergröße aus den Gerätefähigkeiten
- Mehrere Scans werden als Seiten gesammelt: drehen, umsortieren, löschen, Vorschau
- Export als PDF (mit korrekter physischer Seitengröße) oder als JPEG/PNG

## Voraussetzungen

- macOS 13 oder neuer
- Xcode Command Line Tools (`xcode-select --install`) – Xcode selbst ist nicht nötig
- Der Drucker muss **im Netzwerk** sein (LAN oder WLAN). Über USB funktioniert WSD nicht.

## Bauen

```bash
./build-app.sh
open "build/Dell Scan.app"
```

Beim ersten Start fragt macOS nach Zugriff auf das **lokale Netzwerk** – bitte erlauben.
Firewalls wie Little Snitch müssen UDP-Port 3702 (Suche) und HTTP zum Drucker zulassen.

## Fehlersuche

Die App hat einen Kommandozeilenmodus, der jeden Schritt ausgibt:

```bash
"build/Dell Scan.app/Contents/MacOS/DellScan" --cli <Drucker-IP> ~/Desktop/test.pdf [Platen|ADF|ADFDuplex]
```

Wird der Drucker nicht gefunden: Im Web-Interface des Druckers prüfen, ob WSD aktiviert ist.

Zum Entwickeln ohne Drucker gibt es einen einfachen WSD-Simulator:

```bash
python3 Tools/mockwsd.py beispiel.jpg 3     # 3 Seiten im "Einzug"
.build/debug/DellScan --cli 127.0.0.1 /tmp/test.pdf ADF
```

## Aufbau

| Datei | Inhalt |
| --- | --- |
| `WSDiscovery.swift` | WS-Discovery-Probe (UDP 3702, Multicast + Unicast) |
| `WSDScanner.swift` | SOAP-Client: Metadaten, `GetScannerElements`, `CreateScanJob`, `RetrieveImage` (MTOM) |
| `ScannedPage.swift` | Seitenmodell, Drehen, PDF-/Bildexport |
| `ScanModel.swift` | App-Zustand |
| `Views.swift` | SwiftUI-Oberfläche |

Protokoll-Referenz: [sane-airscan](https://github.com/alexpevzner/sane-airscan) (WSD-Backend für Linux).

## Lizenz

MIT – siehe [LICENSE](LICENSE).
