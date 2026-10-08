# Gruppen-Netzwerk-App mit OpenTofu

Referenz-Template fuer die User Story: VMs einer Gruppe liegen im selben Netz;
Ping und SSH zwischen den VMs sind moeglich.

## Architektur

Standardmaessig zwei Ubuntu-VMs pro Gruppe (`vms_per_group`: 2 bis 8).
Jede Gruppe erhaelt ein eigenes OpenStack-L2-Netz und IPv4-Subnetz.
Alle Gruppen nutzen 10.77.0.0/24 in getrennten Netzen ohne Router.
Die VMs haben die Uebungsadressen 10.77.0.11 bis 10.77.0.18.
Eine zweite, vorhandene Zugangsschnittstelle dient dem Zugriff aus Campus/VPN.
Security Groups erlauben im Uebungsnetz nur SSH (TCP 22) und ICMP zwischen
Ports derselben Gruppe, fuer beide Richtungen. IPv6-Regeln sind vorbereitet;
das Uebungsnetz selbst ist aktuell IPv4. Die Zugangsschnittstelle verwendet
die vom Betreiber gewaehlte Security Group. Deren Regeln muessen separat den
gewollten Zugang und die Isolation auf dem gemeinsamen Zugangsnetz sichern.

Cloud-init konfiguriert die Uebungsschnittstelle anhand ihrer MAC-Adresse,
ohne Default-Route/DNS, und legt dieselben persoenlichen SSH-Konten auf allen
VMs der Gruppe an. Konten haben kein sudo. Linux-Namen werden stabil aus der
E-Mail gehasht; Passwortlogin bleibt erhalten. Der Output-Key verwendet den
E-Mail-Lokalteil fuer den bestehenden Plattformvertrag. Kollisionen innerhalb
einer Gruppe werden abgelehnt. Die Plattform zeigt weiterhin die erste VM;
`team_vms.<gruppe>.vms` enthaelt die vollstaendige VM-Liste samt Lab-Adressen.

## OpenTofu und Plattform

Getestet mit OpenTofu 1.13.1. `terraform/` und der HCL-Block `terraform {}`
bleiben als kompatibles Konfigurationsformat erhalten. CI verwendet nur `tofu`,
keine Terraform-Cloud-Tokens und keinen Cloud-Apply. Provider sind im
committeten Lockfile fixiert. Packer baut ein Ubuntu-22.04-Image mit SSH/Ping.
Packer ist ein separater Image-Build-Schritt und wird nicht durch OpenTofu ersetzt.

Der vorhandene Plattform-Worker verwendet derzeit noch die Terraform-CLI.
Diese Repositories sind fuer OpenTofu vorbereitet; eine Migration des Workers
und seiner PostgreSQL-States ist ein separates Arbeitspaket. Keine produktiven
States wurden umgestellt. Bestehende Deployments dieses alten Templates brauchen
vor einem Versionswechsel einen State-/Planvergleich: Ressourcenadressen und
VM-Anzahl haben sich geaendert. Neue Deployments verwenden einen neuen State.

## Lokal starten

1. OpenTofu 1.13.1 und optional Packer installieren.
2. OpenStack-Profil `openstack` in clouds.yaml konfigurieren, nicht committen.
3. Fuer den optionalen Packer-Build Projekt-Netze und Security Groups explizit
   setzen; die Vorlage enthaelt keine projektspezifischen UUID-Defaults.
4. `terraform/terraform.tfvars` lokal anlegen, beispielsweise:

```hcl
image_name         = "freigegebenes-ubuntu-image"
network_uuid       = "UUID-des-Zugangsnetzes"
shared_secgroup_id = "UUID-der-Zugangs-Security-Group"
users = {
  "Gruppe 1" = [{ email = "alice@example.test" }, { email = "bob@example.test" }]
  "Gruppe 2" = [{ email = "carol@example.test" }]
}
vms_per_group = 2
```

```sh
tofu -chdir=terraform init
tofu -chdir=terraform fmt -check -recursive
tofu -chdir=terraform validate
tofu -chdir=terraform test
# Nur im autorisierten Testprojekt:
tofu -chdir=terraform plan -out=lab.tfplan
tofu -chdir=terraform apply lab.tfplan
```

Projekt benoetigt Quota fuer Netze, Subnetze, Ports, Security Groups und VMs.
Das Zugangsnetz darf nicht 10.77.0.0/24 verwenden, sonst entsteht ein
Routingkonflikt. `user_accounts` und State enthalten Passwoerter und muessen
zugriffsgeschuetzt behandelt werden. Keine Zugangsdaten in CI-Artefakte kopieren.

## Akzeptanzpruefung im Testprojekt

Die Cloud-Pruefung ist bewusst manuell und wurde hier nicht ausgefuehrt.

1. Zwei Gruppen mit je zwei VMs provisionieren. Nach `cloud-init status --wait`
   auf allen VMs die Netz-ID je Gruppe anhand `team_vms` pruefen.
2. Auf VM 1 jeder Gruppe: `ping -c 3 -W 2 10.77.0.12`, danach
   `ssh -o ConnectTimeout=10 <eigener-linux-name>@10.77.0.12`.
   Mit dem eigenen Passwort anmelden und `hostname` pruefen.
3. Auf VM 2 umgekehrt Ping/SSH nach 10.77.0.11 pruefen.
4. Gegenseitige Benutzerzugriffe auf fremde persoenliche Home-Verzeichnisse
   muessen abgelehnt werden. Die andere Gruppe besitzt ein getrenntes L2-Netz;
   ihr identischer IP-Bereich bezeichnet keine fremden VMs.
5. Zugriff auf fremde Gruppen ueber das gemeinsame Zugangsnetz separat gegen
   die Betreiber-Security-Group pruefen. Das Lab-Netz allein isoliert diese NIC nicht.
6. Nach dem Test nur den zugehoerigen neuen Test-State mit `tofu destroy` abbauen.

`tofu test` nutzt ausschliesslich Mock-Provider. Es prueft Netzzuordnung,
VM-Anzahl, getrennte Gruppen, NICs, ICMP/SSH-Regeln, Outputs, leeren Roster
und ungueltige VM-Anzahlen. Es beweist keine reale Ping-/SSH-Verbindung.

Das neue Repository `group-network-app` ist eine eigenstaendige Kopie dieses
Referenz-Templates. Anpassungen an der Laufzeit gehoeren nach `packer/`;
Gruppen-Netzwerk und Zugangsvertrag liegen unter `terraform/`.
