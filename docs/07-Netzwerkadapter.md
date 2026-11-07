# 7 Netzwerkadapter für den Mac

Stand der Recherche: 7. November 2026. Preise sind Richtwerte (Geizhals bzw. Herstellerpreis), **ohne Gewähr**. Vor dem Kauf bitte aktuelle Preise prüfen. Mit 2110 Viewer und Blackmagic-Hardware geprüft ist bisher **keiner** dieser Adapter; das ist Teil des Testplans (Abschnitt 0.10).

## Was der Adapter können muss

| Anforderung | Warum |
|---|---|
| **10GBASE-T (RJ-45) mit 10 Gbit/s** | Der Blackmagic 2110 IP Converter 3x3G hat eine RJ-45-Buchse für **10/100/1000/10G BASE-T** – laut technischen Daten ohne 2,5G/5G (NBASE-T). Ein 2,5G- oder 5G-Adapter fällt direkt am Converter auf **1 Gbit/s** zurück; das reicht für unkomprimiertes HD nicht (1080p25 ≈ 1,1 Gbit/s, 1080p50 ≈ 2,2 Gbit/s). |
| **Thunderbolt 3/4/5 oder USB4** | 10 Gbit/s plus Protokollaufwand passen nicht durch USB 3.x. |
| **Treiber in macOS enthalten** | Ohne Installation, ohne Kernel-Erweiterung. Adapter mit Marvell/Aquantia-AQtion-Chip (AQC107/AQC113) laufen unter macOS ohne zusätzlichen Treiber. |
| **MTU 1500 genügt** | 2110 Viewer und der 3x3G nutzen Standardpakete; Jumbo-Frames sind nicht nötig. |

Mit einem **Switch** dazwischen sind auch 5G-Adapter denkbar: Der Switch spricht 10G mit dem Converter und 5G mit dem Mac. Ein 5G-Anschluss trägt einen 1080p50-Strom mit Ton, aber nicht drei. Diese Variante ist günstiger, aber am wenigsten erprobt.

## Empfehlungen

| Adapter | Anschluss | Chip | Preis (Richtwert) | Hinweis |
|---|---|---|---|---|
| **Eingebautes 10-GbE** im Mac mini M4 (Konfigurationsoption beim Kauf) bzw. Mac Studio (10-GbE serienmäßig) | RJ-45 | – | Aufpreis im Apple-Konfigurator | Kein Adapter nötig, ideal für einen festen Arbeitsplatz. Ausstattung im Datenblatt des jeweiligen Modells prüfen |
| **Sonnet Solo10G** (SOLO10G-TB3) | Thunderbolt 3, RJ-45 | AQtion | ab ca. 230–270 € (Geizhals, Juli–Sept. 2026) | Weit verbreitet, Hersteller nennt Apple-Silicon-Kompatibilität |
| **OWC Thunderbolt 10G Ethernet Adapter** (TB3/TB4) | Thunderbolt, RJ-45 | AQtion | 165–200 USD beim Hersteller | In Deutschland seltener im Handel |
| **Günstige Thunderbolt-10GbE-Adapter** (z. B. ORICO, IOCREST) | Thunderbolt 3, RJ-45 | meist AQC107 | ca. 85–130 USD (Händlerangaben, Testbericht) | **Günstigste Option.** Wärmeentwicklung und Kabelqualität beachten; vorher mit 2110 Viewer testen |
| **Sonnet Solo10G SFP+** | Thunderbolt, SFP+ | AQtion | ab ca. 340 € | Nur sinnvoll mit SFP+-Switch; der 3x3G selbst hat RJ-45 |

**Nicht geeignet** für den direkten Anschluss an den 3x3G: USB-C-Adapter mit 1G, 2,5G oder 5G sowie WLAN.

## Kabel

* Cat 6a (bis 100 m) oder Cat 6 (bis ca. 55 m) für 10GBASE-T.
* Der 3x3G hat PoE+ an der RJ-45-Buchse. Er wird über das eigene Netzteil versorgt; ein Mac-Adapter liefert kein PoE, was kein Problem ist.

## Einstellungen am Mac

1. Adapter anschließen; er erscheint in Systemeinstellungen › Netzwerk, z. B. als „Thunderbolt-Ethernet“.
2. IP-Adresse im Netz der Blackmagic-Geräte: per DHCP (die Geräte sind ab Werk auf DHCP) oder manuell im selben Subnetz.
3. In 2110 Viewer unter Erweitert › Netzwerk erscheint der Adapter mit Name, Adresse und Geschwindigkeit. „Automatisch“ wählt ihn, sobald er im Netz des Senders liegt.

## Quellen

* Blackmagic Design, technische Daten 2110 IP Converter 3x3G: https://www.blackmagicdesign.com/products/blackmagic2110ipconverter/techspecs
* Sonnet Solo10G: https://www.sonnettech.com/product/solo10g-tb3/overview.html, https://www.sonnetstore.com/products/solo10g-thunderbolt-adapter
* Geizhals: https://geizhals.de/sonnet-solo-10g-thunderbolt-3-edition-solo10g-tb3-a1819684.html, https://geizhals.de/sonnet-solo-10g-sfp-thunderbolt-3-edition-solo10g-sfp-t3-a2163995.html
* OWC: https://eshop.macsales.com/item/OWC/TB3ADP10GBE/
* ORICO: https://oricotechs.com/products/orico-thunderbolt-network-adapter
* IOCREST-Test: https://www.michaelstinkerings.org/iocrest-thunderbolt-10g-nic-review/
* Mac mini M4 mit 10 Gigabit Ethernet (Händlerangaben): https://www.galaxus.at/en/s1/questionandanswer/does-this-version-have-10-gigabit-ethernet-or-only-1-gigabit-ethernet-thank-you-very-much-835296
