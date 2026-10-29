package main

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"strings"
)

type Profile struct {
	Gateway string `json:"gateway"`
	DNS     string `json:"dns"`
}
type Roam struct {
	Enabled  bool `json:"enabled"`
	Target2G int  `json:"target2g"`
	Target5G int  `json:"target5g"`
	MinGain  int  `json:"min_gain"`
}
type Config struct {
	Enabled   bool                         `json:"enabled"`
	Profiles  map[string]Profile           `json:"profiles"`
	Roam      Roam                         `json:"roam"`
	MeshNodes map[string]map[string]string `json:"mesh_nodes,omitempty"`
}

// Accept remote interface mappings only for nodes verified against their SSIDs.
func meshInterface(raw []byte, c Config) (string, string) {
	var station struct {
		Parent string `json:"parent"`
		Ifname string `json:"ifname"`
		Assoc  int    `json:"assoc"`
	}
	if json.Unmarshal(raw, &station) != nil || station.Assoc != 1 {
		return "", ""
	}
	parent := strings.ToUpper(station.Parent)
	iface := c.MeshNodes[parent][station.Ifname]
	if iface != "wl0" && iface != "wl1" && iface != "wl2" {
		return "", ""
	}
	return iface, parent
}

// packetMAC admits only complete, unfragmented IPv4 DHCP client requests.
func packetMAC(p []byte) ([]byte, int, bool) {
	if len(p) < 28 || p[0]>>4 != 4 || p[9] != 17 {
		return nil, 0, false
	}
	iplen := int(p[0]&15) * 4
	if iplen < 20 || len(p) < iplen+8+240 || binary.BigEndian.Uint16(p[6:8])&0x3fff != 0 {
		return nil, 0, false
	}
	total := int(binary.BigEndian.Uint16(p[2:4]))
	if total > len(p) || total < iplen+248 {
		return nil, 0, false
	}
	u := p[iplen:]
	if binary.BigEndian.Uint16(u[:2]) != 68 || binary.BigEndian.Uint16(u[2:4]) != 67 || int(binary.BigEndian.Uint16(u[4:6])) != total-iplen {
		return nil, 0, false
	}
	b := p[iplen+8 : total]
	if b[0] != 1 || b[1] != 1 || b[2] != 6 || !bytes.Equal(b[24:28], []byte{0, 0, 0, 0}) || !bytes.Equal(b[236:240], []byte{99, 130, 83, 99}) {
		return nil, 0, false
	}
	return b[28:34], iplen, true
}

// Add a locally verified circuit ID for dnsmasq's standard per-tag options.
// Preserve every client option except an untrusted preexisting relay-agent ID.
func tagPacket(p []byte, iface string) ([]byte, error) {
	_, iplen, ok := packetMAC(p)
	if !ok {
		return nil, fmt.Errorf("not a DHCP request")
	}
	if iface != "wl0" && iface != "wl1" && iface != "wl2" {
		return nil, fmt.Errorf("unmanaged interface")
	}
	total := int(binary.BigEndian.Uint16(p[2:4]))
	start := iplen + 8 + 240
	q := append([]byte{}, p[:start]...)
	foundEnd := false
	for i := start; i < total; {
		code := p[i]
		if code == 255 {
			foundEnd = true
			break
		}
		if code == 0 {
			q = append(q, 0)
			i++
			continue
		}
		if i+2 > total {
			return nil, fmt.Errorf("truncated option")
		}
		n := int(p[i+1]) + 2
		if i+n > total {
			return nil, fmt.Errorf("truncated option data")
		}
		if code != 82 {
			q = append(q, p[i:i+n]...)
		}
		i += n
	}
	if !foundEnd {
		return nil, fmt.Errorf("missing end option")
	}
	id := []byte("meshgw_" + iface)
	q = append(q, 82, byte(len(id)+2), 1, byte(len(id)))
	q = append(q, id...)
	q = append(q, 255)
	for len(q) < iplen+8+300 {
		q = append(q, 0)
	}
	if len(q) > 1500 {
		return nil, fmt.Errorf("packet exceeds MTU")
	}
	binary.BigEndian.PutUint16(q[2:4], uint16(len(q)))
	binary.BigEndian.PutUint16(q[iplen+4:iplen+6], uint16(len(q)-iplen))
	// IPv4 UDP permits a zero checksum; the IP header checksum must be updated.
	q[iplen+6] = 0
	q[iplen+7] = 0
	q[10] = 0
	q[11] = 0
	var sum uint32
	for i := 0; i < iplen; i += 2 {
		sum += uint32(binary.BigEndian.Uint16(q[i : i+2]))
	}
	for sum>>16 != 0 {
		sum = (sum & 65535) + (sum >> 16)
	}
	binary.BigEndian.PutUint16(q[10:12], ^uint16(sum))
	return q, nil
}
