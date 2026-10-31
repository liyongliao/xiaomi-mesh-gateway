package main

import (
	"bytes"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

const queue = 3131
const base = "/userdisk/mesh-gateway"

var seq uint32
var stateMu sync.Mutex
var state = struct {
	Started string              `json:"started"`
	Running bool                `json:"running"`
	Packets uint64              `json:"packets"`
	Tagged  map[string]uint64   `json:"tagged"`
	Last    []map[string]string `json:"last"`
}{Started: time.Now().Format(time.RFC3339), Running: true, Tagged: map[string]uint64{}, Last: []map[string]string{}}

func attr(kind uint16, b []byte) []byte {
	n := len(b) + 4
	out := make([]byte, (n+3)&^3)
	binary.LittleEndian.PutUint16(out[:2], uint16(n))
	binary.LittleEndian.PutUint16(out[2:4], kind)
	copy(out[4:], b)
	return out
}
func be32(n uint32) []byte { b := make([]byte, 4); binary.BigEndian.PutUint32(b, n); return b }
func send(fd int, kind uint16, attrs []byte, ack bool) error {
	seq++
	b := make([]byte, 20+len(attrs))
	binary.LittleEndian.PutUint32(b[:4], uint32(len(b)))
	binary.LittleEndian.PutUint16(b[4:6], 0x300|kind)
	flags := uint16(1)
	if ack {
		flags |= 4
	}
	binary.LittleEndian.PutUint16(b[6:8], flags)
	binary.LittleEndian.PutUint32(b[8:12], seq)
	b[16] = 2
	binary.BigEndian.PutUint16(b[18:20], queue)
	copy(b[20:], attrs)
	return syscall.Sendto(fd, b, 0, &syscall.SockaddrNetlink{Family: syscall.AF_NETLINK})
}
func checkAck(fd int) error {
	b := make([]byte, 4096)
	n, _, e := syscall.Recvfrom(fd, b, 0)
	if e != nil {
		return e
	}
	msgs, e := syscall.ParseNetlinkMessage(b[:n])
	if e != nil {
		return e
	}
	for _, m := range msgs {
		if m.Header.Type == 2 && len(m.Data) >= 4 {
			v := int32(binary.LittleEndian.Uint32(m.Data[:4]))
			if v != 0 {
				return syscall.Errno(-v)
			}
			return nil
		}
	}
	return fmt.Errorf("missing queue configuration acknowledgement")
}
func loadConfig() Config {
	var c Config
	b, e := os.ReadFile(base + "/config.json")
	if e == nil {
		_ = json.Unmarshal(b, &c)
	}
	return c
}
func interfaceFor(mac []byte, phys uint32) string {
	if phys != 0 {
		for _, i := range []string{"wl0", "wl1", "wl2"} {
			b, _ := os.ReadFile("/sys/class/net/" + i + "/ifindex")
			if strings.TrimSpace(string(b)) == strconv.Itoa(int(phys)) {
				return i
			}
		}
	}
	b, e := os.ReadFile("/sys/class/net/br-lan/brforward")
	if e != nil {
		return ""
	}
	port := -1
	for i := 0; i+16 <= len(b); i += 16 {
		if b[i+7] == 0 && bytes.Equal(b[i:i+6], mac) {
			port = int(b[i+6]) | int(b[i+12])<<8
			break
		}
	}
	if port < 0 {
		return ""
	}
	for _, i := range []string{"wl0", "wl1", "wl2"} {
		p, _ := os.ReadFile("/sys/class/net/br-lan/brif/" + i + "/port_no")
		v, _ := strconv.ParseInt(strings.TrimSpace(string(p)), 0, 32)
		if int(v) == port {
			return i
		}
	}
	return ""
}
func saveState() {
	stateMu.Lock()
	defer stateMu.Unlock()
	b, _ := json.Marshal(state)
	_ = os.WriteFile("/tmp/mesh-gateway-status.json.new", b, 0600)
	_ = os.Rename("/tmp/mesh-gateway-status.json.new", "/tmp/mesh-gateway-status.json")
}

func main() {
	time.Local = time.FixedZone("Asia/Shanghai", 8*60*60)
	state.Started = time.Now().Format(time.RFC3339)
	log.SetFlags(log.LstdFlags)
	fd, e := syscall.Socket(syscall.AF_NETLINK, syscall.SOCK_RAW, 12)
	if e != nil {
		log.Fatal(e)
	}
	defer syscall.Close(fd)
	if e = syscall.Bind(fd, &syscall.SockaddrNetlink{Family: syscall.AF_NETLINK}); e != nil {
		log.Fatal(e)
	}
	_ = syscall.SetsockoptInt(fd, syscall.SOL_SOCKET, syscall.SO_RCVBUF, 1<<20)
	// Bind only our own queue. Never unbind another service's protocol family.
	if e = send(fd, 2, attr(1, []byte{1, 0, 0, 2}), true); e != nil {
		log.Fatal(e)
	}
	if e = checkAck(fd); e != nil {
		log.Fatal(e)
	}
	params := append(attr(2, []byte{0, 0, 255, 255, 2}), attr(3, be32(1024))...)
	params = append(params, attr(4, be32(1))...)
	params = append(params, attr(5, be32(1))...)
	if e = send(fd, 2, params, true); e != nil {
		log.Fatal(e)
	}
	if e = checkAck(fd); e != nil {
		log.Fatal(e)
	}
	_ = os.WriteFile("/tmp/mesh-gateway-queue.ready", []byte(strconv.Itoa(os.Getpid())), 0600)
	defer os.Remove("/tmp/mesh-gateway-queue.ready")
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGTERM, syscall.SIGINT)
	go func() { <-signals; os.Remove("/tmp/mesh-gateway-queue.ready"); os.Exit(0) }()
	go func() {
		for {
			saveState()
			time.Sleep(5 * time.Second)
		}
	}()
	log.Printf("DHCP queue %d ready, bypass on service failure", queue)
	b := make([]byte, 131072)
	for {
		n, _, err := syscall.Recvfrom(fd, b, 0)
		if err != nil {
			if err == syscall.EINTR || err == syscall.ENOBUFS {
				continue
			}
			log.Fatal(err)
		}
		msgs, err := syscall.ParseNetlinkMessage(b[:n])
		if err != nil {
			continue
		}
		for _, m := range msgs {
			if m.Header.Type != 0x300 || len(m.Data) < 4 {
				continue
			}
			var id, phys uint32
			var packet []byte
			for off := 4; off+4 <= len(m.Data); {
				l := int(binary.LittleEndian.Uint16(m.Data[off : off+2]))
				typ := binary.LittleEndian.Uint16(m.Data[off+2:off+4]) & 0x3fff
				if l < 4 || off+l > len(m.Data) {
					break
				}
				v := m.Data[off+4 : off+l]
				switch typ {
				case 1:
					if len(v) >= 4 {
						id = binary.BigEndian.Uint32(v[:4])
					}
				case 7:
					if len(v) >= 4 {
						phys = binary.BigEndian.Uint32(v[:4])
					}
				case 10:
					packet = v
				}
				off += (l + 3) &^ 3
			}
			verdict := append(be32(1), be32(id)...)
			attrs := attr(2, verdict)
			mac, _, ok := packetMAC(packet)
			iface := ""
			via := ""
			c := loadConfig()
			if ok && c.Enabled {
				iface = interfaceFor(mac, phys)
				if _, exists := c.Profiles[iface]; exists {
					if modified, err := tagPacket(packet, iface); err == nil {
						attrs = append(attrs, attr(10, modified)...)
					} else {
						iface = ""
					}
				} else {
					iface = ""
				}
			}
			if err := send(fd, 1, attrs, false); err != nil {
				log.Fatal(err)
			}
			stateMu.Lock()
			state.Packets++
			if iface != "" {
				state.Tagged[iface]++
				state.Last = append(state.Last, map[string]string{"time": time.Now().Format("15:04:05"), "interface": iface, "mac": hex.EncodeToString(mac), "gateway": c.Profiles[iface].Gateway, "via": via})
				if len(state.Last) > 12 {
					state.Last = state.Last[len(state.Last)-12:]
				}
			}
			stateMu.Unlock()
		}
	}
}
