# =====================================================================
#  MikroTik CCR2004-16G-2S+  ISP-A (AS 65001)
#   ether8  10.1.50.1/24   -> Casa 3 (WAN del TP-Link, IP por DHCP)
#   ether6  troncal        -> SW-NUBE-A Gi0/1  (VLAN 203 -> R4, VLAN 211 -> R1)
#   ether7  troncal        -> SW-NUBE-B Gi0/1  (VLAN 202 -> R5, VLAN 213 -> R3)
#   ether5  190.0.50.1/30  -> Vivobook (VM VyOS, salida real a Internet) + 192.168.99.1/24 gestion (WinBox desde la Vivobook)
#  Aplicar una linea a la vez y esperar el prompt.
# =====================================================================

# ---- PASO 0: respaldar la configuracion actual y restablecer el equipo ----
/export file=red-casera-antes-v5
/system reset-configuration no-defaults=yes keep-users=yes skip-backup=yes
# (el equipo se reinicia; volver a entrar por WinBox con la direccion MAC)

# ---- PASO 1: VLANs y direcciones ----
/system identity set name=MK-ISP-A
/interface vlan add name=v203-R4 vlan-id=203 interface=ether6
/interface vlan add name=v211-R1 vlan-id=211 interface=ether6
/interface vlan add name=v202-R5 vlan-id=202 interface=ether7
/interface vlan add name=v213-R3 vlan-id=213 interface=ether7
/ip address add address=10.0.3.1/30 interface=v203-R4 comment="Hacia R4 ISP-C"
/ip address add address=10.1.1.1/30 interface=v211-R1 comment="Hacia R1 borde principal"
/ip address add address=10.0.2.1/30 interface=v202-R5 comment="Hacia R5 ISP-B"
/ip address add address=10.1.3.1/30 interface=v213-R3 comment="Hacia R3 borde respaldo"
/ip address add address=10.1.50.1/24 interface=ether8 comment="Casa 3"
/ip address add address=190.0.50.1/30 interface=ether5 comment="Hacia VyOS"
/ip address add address=192.168.99.1/24 interface=ether5 comment="Gestion (WinBox desde la Vivobook 192.168.99.2)"
/ip route add dst-address=0.0.0.0/0 gateway=190.0.50.2 comment="Salida real via VyOS"
/ip dns set allow-remote-requests=yes servers=8.8.8.8,1.1.1.1

# ---- PASO 2: BGP (RouterOS 7.20 o posterior) ----
/routing bgp instance add name=bgp1 as=65001 router-id=10.255.0.1
/routing bgp connection add name=R4 instance=bgp1 local.role=ebgp remote.address=10.0.3.2 remote.as=65003 hold-time=15s keepalive-time=5s output.redistribute=connected output.default-originate=always
/routing bgp connection add name=R5 instance=bgp1 local.role=ebgp remote.address=10.0.2.2 remote.as=65002 hold-time=15s keepalive-time=5s output.redistribute=connected output.default-originate=always
/routing bgp connection add name=R1 instance=bgp1 local.role=ebgp remote.address=10.1.1.2 remote.as=65004 hold-time=15s keepalive-time=5s output.redistribute=connected output.default-originate=always
/routing bgp connection add name=R3 instance=bgp1 local.role=ebgp remote.address=10.1.3.2 remote.as=65004 hold-time=15s keepalive-time=5s output.redistribute=connected output.default-originate=always
# En RouterOS anterior a 7.20 (sin "instance"), usar en cada conexion
#   as=65001 router-id=10.255.0.1   en lugar de   instance=bgp1

# ---- PASO 3: proteccion anti-DDoS hacia el servidor publicado ----
/ip firewall filter add chain=forward action=accept connection-state=established,related comment="DDoS: trafico establecido"
/ip firewall filter add chain=forward action=accept connection-state=new dst-address=10.1.40.13 dst-limit=100,200,src-address/1m40s comment="DDoS: hasta 100 conexiones/s por origen"
/ip firewall filter add chain=forward action=add-src-to-address-list connection-state=new dst-address=10.1.40.13 address-list=ddos-bloqueados address-list-timeout=10m comment="DDoS: origen excedido, 10 min"
/ip firewall filter add chain=forward action=drop connection-state=new dst-address=10.1.40.13 comment="DDoS: descarte"
/ip firewall raw add chain=prerouting action=drop src-address-list=ddos-bloqueados comment="DDoS: origenes bloqueados"

# ---- Comprobar ----
# /routing bgp session print        (4 sesiones con E)
# /ip route print where dst-address=10.1.40.13/32

# ---- DHCP para la Casa 3 (ether8) ----
/ip pool add name=casa3 ranges=10.1.50.10-10.1.50.50
/ip dhcp-server network add address=10.1.50.0/24 gateway=10.1.50.1 dns-server=8.8.8.8,1.1.1.1
/ip dhcp-server add name=dhcp-casa3 interface=ether8 address-pool=casa3 disabled=no
