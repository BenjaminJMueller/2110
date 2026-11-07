# Network adapters for the Mac

[Deutsch](../07-Netzwerkadapter.md)

Research as of 7 November 2026. Prices are approximate (Geizhals price comparison or manufacturer price) and **without guarantee**. Please check current prices before buying. **None** of these adapters has been tested with 2110 Viewer and Blackmagic hardware yet; that is part of the test plan.

## What the adapter must do

| Requirement | Why |
|---|---|
| **10GBASE-T (RJ-45) at 10 Gbit/s** | The Blackmagic 2110 IP Converter 3x3G has an RJ-45 port for **10/100/1000/10G BASE-T**. According to its tech specs it does not support 2.5G or 5G (NBASE-T). A 2.5G or 5G adapter connected directly to the converter falls back to **1 Gbit/s**, which is not enough for uncompressed HD (1080p25 ≈ 1.1 Gbit/s, 1080p50 ≈ 2.2 Gbit/s). |
| **Thunderbolt 3/4/5 or USB4** | 10 Gbit/s plus protocol overhead do not fit through USB 3.x. |
| **Driver included in macOS** | No installation, no kernel extension. Adapters with a Marvell/Aquantia AQtion chip (AQC107/AQC113) work on macOS without an extra driver. |
| **MTU 1500 is enough** | 2110 Viewer and the 3x3G use standard packets; jumbo frames are not needed. |

With a **switch** in between, 5G adapters are possible: the switch talks 10G to the converter and 5G to the Mac. A 5G link carries one 1080p50 stream with audio, but not three. This option is cheaper but the least tested.

## Recommendations

| Adapter | Connection | Chip | Price (approx.) | Note |
|---|---|---|---|---|
| **Built-in 10GbE** in Mac mini M4 (build-to-order option) or Mac Studio (10GbE standard) | RJ-45 | – | surcharge in Apple’s configurator | No adapter needed, ideal for a fixed workstation. Check the spec sheet of the model |
| **Sonnet Solo10G** (SOLO10G-TB3) | Thunderbolt 3, RJ-45 | AQtion | from about €230–270 (Geizhals, July–Sept. 2026) | Widely used; the manufacturer states Apple silicon compatibility |
| **OWC Thunderbolt 10G Ethernet Adapter** (TB3/TB4) | Thunderbolt, RJ-45 | AQtion | 165–200 USD from the manufacturer | Less common in German retail |
| **Low-cost Thunderbolt 10GbE adapters** (e.g. ORICO, IOCREST) | Thunderbolt 3, RJ-45 | mostly AQC107 | about 85–130 USD (retailer information, review) | **Cheapest option.** Watch heat and cable quality; test with 2110 Viewer first |
| **Sonnet Solo10G SFP+** | Thunderbolt, SFP+ | AQtion | from about €340 | Only useful with an SFP+ switch; the 3x3G itself has RJ-45 |

**Not suitable** for a direct connection to the 3x3G: USB-C adapters with 1G, 2.5G or 5G, and Wi-Fi.

## Cables

* Cat 6a (up to 100 m) or Cat 6 (up to about 55 m) for 10GBASE-T.
* The 3x3G has PoE+ on its RJ-45 port. It is powered by its own power supply; a Mac adapter supplies no PoE, which is not a problem.

## Settings on the Mac

1. Connect the adapter; it appears in System Settings › Network, for example as “Thunderbolt Ethernet”.
2. IP address in the Blackmagic devices’ network: via DHCP (the devices use DHCP by default) or manually in the same subnet.
3. In 2110 Viewer, Advanced › Network lists the adapter with name, address and speed. “Automatic” picks it as soon as it is in the sender’s network.

## Sources

* Blackmagic Design, tech specs 2110 IP Converter 3x3G: https://www.blackmagicdesign.com/products/blackmagic2110ipconverter/techspecs
* Sonnet Solo10G: https://www.sonnettech.com/product/solo10g-tb3/overview.html, https://www.sonnetstore.com/products/solo10g-thunderbolt-adapter
* Geizhals: https://geizhals.de/sonnet-solo-10g-thunderbolt-3-edition-solo10g-tb3-a1819684.html, https://geizhals.de/sonnet-solo-10g-sfp-thunderbolt-3-edition-solo10g-sfp-t3-a2163995.html
* OWC: https://eshop.macsales.com/item/OWC/TB3ADP10GBE/
* ORICO: https://oricotechs.com/products/orico-thunderbolt-network-adapter
* IOCREST review: https://www.michaelstinkerings.org/iocrest-thunderbolt-10g-nic-review/
* Mac mini M4 with 10 Gigabit Ethernet (retailer information): https://www.galaxus.at/en/s1/questionandanswer/does-this-version-have-10-gigabit-ethernet-or-only-1-gigabit-ethernet-thank-you-very-much-835296
