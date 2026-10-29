# Gruppen-Netzwerk-App mit OpenTofu

Mehrere Ubuntu-VMs je Gruppe fuer Ping-/SSH-Uebungen. Deployment-Aufbau nach
`Six7-app-store/Ubuntu-App`, aktueller Main-Stand `8990cfc` (Tag `v2.0.0`):
OpenTofu 1.13.1, OpenStack-Provider 3.4, Ubuntu 24.04 und Cloud-init ohne Packer.
Der aktuelle AppStore-Worker erwartet `tofu/*.tofu` und lehnt `packer/` ab.

## Adressfamilien

`ip_mode` hat die validierten Werte `ipv4`, `ipv6` und `dual`; Standard `ipv6`.

| Modus | Zugangsnetze | Uebungsnetz je Gruppe | Zugangsausgabe |
|---|---|---|---|
| `ipv4` | `network_v4_uuid` | 10.77.0.0/24 | geroutete IPv4 |
| `ipv6` | `network_v6_uuid` | fd77:77::/64 | IPv6, niemals private NAT-IPv4 |
| `dual` | IPv6 primaer, separates IPv4-Netz | beide Subnetze im selben L2-Netz | IPv4 bevorzugt; IPv6 bleibt separat verfuegbar |

Explizit gewaehlte Netz-IDs haben Vorrang; `network_uuid` bleibt als Fallback
fuer die primaere Netz-ID erhalten. Ohne ausgewaehlte ID sucht die App das
IPv6-Zugangsnetz `DHBWV6` bzw. das IPv4-Zugangsnetz `DHBWv4` anhand des Namens
in der Sichtbarkeit des authentifizierten OpenStack-Projekts. Die Namen lassen
sich mit `network_v6_name` und `network_v4_name` aendern. Bei nicht vorhandenen
oder mehrfach gefundenen Namen muss eine eindeutige Projekt-Netz-ID ausgewaehlt
werden. Es werden keine fremden Projekt-UUIDs als Default verwendet.
Fuer `dual` muss das IPv4-Netz
vom primaeren IPv6-Netz verschieden sein und genau ein IPv4-Subnetz besitzen;
CIDR und Gateway werden daraus ausgelesen. Die nach dem Boot angehaengte IPv4-NIC
bekommt statische Adressierung, die Netzwerk-MTU und Quellrouting in Tabelle 100. Ihre Default-Route
ersetzt nicht die primaere Route fuer Paketinstallation und IPv6-Zugang.

Jede belegte Gruppe erhaelt ein eigenes L2-Netz ohne Router zu anderen Gruppen.
Gruppennamen duerfen Unicode, Sonderzeichen und laengere Anzeigenamen enthalten.
Fuer Cloud-Ressourcen werden begrenzte ASCII-Namen mit Hash-Suffix abgeleitet;
Roster-Schluessel und Anzeigenamen bleiben erhalten. Leere Gruppen werden
mitgezaehlt, erzeugen aber keine VMs oder Netze.
Standardmaessig entstehen zwei VMs (`vms_per_group`: 2-8), mit Lab-Adressen
10.77.0.11/12 bzw. fd77:77::b/c. Die Praefixe duerfen nicht mit den Zugangsnetzen
kollidieren. Getrennte Gruppen nutzen dieselben Praefixe in getrennten Netzen.
Die Lab-NIC hat weder Default-Route noch DHCP/RA; OpenTofu reserviert ihre
statischen Adressen auch im Neutron-Port. Ping/SSH ist nur innerhalb der
Gruppen-Security-Group freigegeben. Zusaetzliche ICMPv6-Typen 135/136 erlauben
Neighbour Discovery mit Link-Local-/Multicast-Adressen.

Ohne ausgewaehlte `shared_secgroup_id` erstellt die App eine eigene Zugangs-
Security-Group fuer SSH (TCP 22), Ping und erforderliches ICMPv6. Egress ist fuer
beide IP-Familien erlaubt: Das IPv6-Zugangsnetz kann fuer Paketinstallation
zusaetzlich private NAT-IPv4 verwenden. Die SSH-Quellnetze sind ueber
`ssh_allowed_cidr_v4`/`ssh_allowed_cidr_v6` einstellbar; Standard ist jeweils
der gesamte Adressraum, waehrend die tatsächliche Erreichbarkeit vom
gerouteten Zugangsnetz abhaengt. Wird eine bestehende Security Group ausgewaehlt,
verwendet die App ausschliesslich diese und veraendert ihre Regeln nicht.
Sie muss dann selbst SSH und benoetigte Netzwerkfunktionen erlauben.
Die gewollte Isolation auf dem gemeinsamen Zugangsnetz bleibt eine separate
Betreiberkonfiguration. Ein isoliertes
Lab-Netz isoliert nicht automatisch die zusaetzlichen Zugangsschnittstellen.
Campus/VPN kann erforderlich sein; es wird kein Internetgateway erzeugt.

## Variablen und Zugangsdaten

| Variable | Standard / Zweck |
|---|---|
| `ip_mode` | `ipv6`; IPv4, IPv6 oder beide |
| `network_v4_uuid`, `network_v6_uuid` | ausgewaehlte Projekt-Netze |
| `network_v4_name`, `network_v6_name` | ohne ID: `DHBWv4` bzw. `DHBWV6` |
| `network_uuid` | optionaler Fallback fuer das primaere Netz |
| `shared_secgroup_id` | optional; leer erzeugt eine eigene Zugangs-Security-Group |
| `ssh_allowed_cidr_v4`, `ssh_allowed_cidr_v6` | SSH-Quellnetze der automatischen Group, Standard `0.0.0.0/0` / `::/0` |
| `image_name` | `Ubuntu 24.04` |
| `flavor` | `gp1.small`, alternativ `gp1.medium` oder `gp1.large` |
| `disk_size_gb` | `0` = Flavor-Standard; 10-200 = Cinder-Bootvolume je VM |
| `vms_per_group` | `2`, ganze Zahl zwischen 2 und 8 |
| `users` | Gruppen/Roster, vom Worker gesetzt |

Cloud-init installiert SSH/Ping, richtet die Lab-NIC anhand ihrer MAC ein und
legt persoenliche Konten ohne sudo auf allen VMs ihrer Gruppe an. Die
Home-Verzeichnisse erhalten 0700. Kontonamen werden stabil aus der E-Mail
gehasht; Output-Keys verwenden den Lokalteil fuer den bestehenden
Plattformvertrag. Kollisionen innerhalb einer Gruppe werden abgelehnt.

`user_accounts` zeigt auf die erste Gruppen-VM. `team_vms.<gruppe>` behaelt
`fixed_ip` und ergaenzt `ip_mode`, `fixed_ip_v4`, `fixed_ip_v6` sowie die
vollstaendige Liste `vms` mit Zugang und Lab-Adressen fuer beide Familien.
Eine IPv6-Adresse bleibt im SSH-Hostfeld ungeklammert: `ssh user@2001:db8::10`.
Bei einer URL oder Host:Port-Darstellung sind IPv6-Literale zu klammern.
Passwoerter und State sind sensibel, nicht in Logs/CI-Artefakte kopieren.

## Pruefen und Testdeployment

```sh
tofu -chdir=tofu init -backend=false -input=false -lockfile=readonly
tofu -chdir=tofu fmt -check -recursive
tofu -chdir=tofu validate
tofu -chdir=tofu test
python tests/check_cloud_init.py
```

CI fuehrt nur diese Pruefungen aus, ohne Cloud-Apply und ohne Cloud-Credentials.
Die OpenTofu-Tests verwenden Mock-Provider und pruefen alle drei IP-Modi,
Gruppentrennung, NICs, SSH/ICMP/Neighbour Discovery, Outputs, Bootvolumes und
ungueltige Eingaben. Separate Regressionen bilden den echten Worker-Payload
ohne Netz-IDs und ohne Security-Group-ID fuer alle drei IP-Modi nach und pruefen
explizite Overrides, leere Gruppen sowie falsch adressierte IPv6-Netze.
Der Cloud-init-Test rendert alle drei Modi und prueft
Netplan-Adressierung, MTU, Quellrouting, Konten und die endliche Wartezeit fuer
Hotplug-NICs. Das ist kein Nachweis einer realen Cloud-Verbindung.

Beispiel `tofu/terraform.tfvars` (lokal, nicht committen):

```hcl
ip_mode            = "dual"
network_v4_name    = "DHBWv4"
network_v6_name    = "DHBWV6"
# Optional: eindeutige Netz-IDs und eine bestehende Zugangs-Group auswaehlen.
# Ohne shared_secgroup_id wird die SSH-Zugangs-Group automatisch erzeugt.
users = {
  "Gruppe 1" = [{ email = "alice@example.test" }, { email = "bob@example.test" }]
  "Gruppe 2" = [{ email = "carol@example.test" }]
}
```

Nur im autorisierten Testprojekt: OpenStack-Profil `openstack` konfigurieren,
`tofu -chdir=tofu plan -out=lab.tfplan` pruefen und anwenden. Auf jeder VM
`cloud-init status --wait` pruefen; Installation und NIC-Hotplug koennen dauern.
Dann von VM 1 zu VM 2 (und zurueck):

```sh
# Je nach gewaehltem Modus:
ping -4 -c 3 -W 2 10.77.0.12
ping -6 -c 3 -W 2 fd77:77::c
ssh -4 <eigener-linux-name>@10.77.0.12
ssh -6 <eigener-linux-name>@fd77:77::c
```

Zusaetzlich persoenliche Home-Rechte, getrennte Gruppennetze und Zugriff ueber
beide Zugangsnetze pruefen. Nach dem Test nur den zugehoerigen Test-State
abbauen. Bootvolumes werden mit ihrer jeweiligen VM entfernt.

## Versionen und Migration

Der AppStore waehlt Git-Versionstags, keine Branches ohne Version. Neue
freigegebene Stande muessen einen neuen Tag erhalten; vorhandene Tags bleiben
unveraendert. Der Tag muss auf den geprueften Feature-Branch-Commit zeigen.

Gegenueber dem alten Stand wurden `terraform/` nach `tofu/`, `.tf` nach `.tofu`
umgestellt und Packer entfernt. `flavor_name` wurde durch den aktuellen
Ubuntu-Vertrag `flavor` ersetzt. Standard-Image und IP-Modus sind jetzt
Ubuntu 24.04 / IPv6. Vor Aktualisierung vorhandener Deployments State sichern,
Variablen explizit uebernehmen und Plan auf Ersatz-/Loeschaktionen pruefen.
Es wurde keine bestehende VM und kein Cloud-State migriert.
