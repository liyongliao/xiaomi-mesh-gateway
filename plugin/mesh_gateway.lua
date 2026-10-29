module("luci.controller.mesh_gateway", package.seeall)
local base = "/userdisk/mesh-gateway"
local json = require("luci.json")

function index()
    for _, item in ipairs({{"mesh_gateway", "page"}, {"mesh_gateway_status", "status"}, {"mesh_gateway_save", "save"}}) do
        local n = entry({"web", "prosetting", item[1]}, call(item[2]), "Mesh 与 Wi-Fi 分流", 90)
        n.sysauth = "admin"
        n.sysauth_authenticator = "htmlauth"
        n.leaf = true
    end
end

local function read(path)
    local f=io.open(path,"r"); if not f then return nil end
    local s=f:read("*a"); f:close(); return s
end
local function respond(data, code)
    local h=require("luci.http")
    if code then h.status(code) end
    h.prepare_content("application/json; charset=utf-8")
    h.write(json.encode(data))
end
function page()
    local h=require("luci.http")
    h.header("Cache-Control", "no-store")
    h.header("X-Content-Type-Options", "nosniff")
    h.header("X-Frame-Options", "SAMEORIGIN")
    h.prepare_content("text/html; charset=utf-8")
    h.write(read(base.."/index.html") or "Plugin file missing")
end
function status()
    local u=require("luci.model.uci").cursor()
    local profiles={}
    u:foreach("wireless", "wifi-iface", function(s)
        if s.ifname=="wl0" or s.ifname=="wl1" or s.ifname=="wl2" then
            local clients={}
            local p=io.popen("iwinfo "..s.ifname.." assolist 2>/dev/null")
            if p then
                for line in p:lines() do
                    local mac,rssi=line:match("^([%x:]+)%s+.-%s(%-%d+)%s+dBm")
                    if mac then clients[#clients+1]={mac=mac,rssi=tonumber(rssi)} end
                end
                p:close()
            end
            profiles[#profiles+1]={ifname=s.ifname,ssid=s.ssid,clients=clients}
        end
    end)
    local cfg=read(base.."/config.json")
    local runtime=read("/tmp/mesh-gateway-status.json")
    local topology={}
    local ok,t=pcall(function() return require("xiaoqiang.module.XQTopology").topologicalGraph() end)
    if ok then topology=t end
    respond({config=cfg and json.decode(cfg) or {},profiles=profiles,runtime=runtime and json.decode(runtime) or {},topology=topology,ready=read("/tmp/mesh-gateway-queue.ready")~=nil})
end
local function ip(value, gateway)
    if type(value)~="string" then return false end
    local a,b,c,d=value:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    a,b,c,d=tonumber(a),tonumber(b),tonumber(c),tonumber(d)
    if not a or a<1 or a>=224 or not b or b>255 or not c or c>255 or not d or d>255 then return false end
    if gateway then return a==192 and b==168 and c==31 and d>0 and d<255 end
    return true
end
function save()
    local h=require("luci.http")
    if h.getenv("REQUEST_METHOD")~="POST" then respond({error="请使用保存按钮。"},405);return end
    local origin=h.getenv("HTTP_ORIGIN")
    local host=h.getenv("HTTP_HOST") or "192.168.31.1"
    if origin and origin~="http://"..host and origin~="https://"..host then respond({error="请求来源不匹配。"},403);return end
    local raw=h.formvalue("config") or ""
    if #raw>4096 then respond({error="配置过长。"},400);return end
    local ok,c=pcall(json.decode,raw)
    if not ok or type(c)~="table" or type(c.profiles)~="table" or type(c.roam)~="table" or type(c.enabled)~="boolean" then respond({error="配置格式错误。"},400);return end
    local clean={enabled=c.enabled,profiles={},roam={}}
    for _,i in ipairs({"wl0","wl1","wl2"}) do
        local p=c.profiles[i]
        if type(p)~="table" or not ip(p.gateway,true) or not ip(p.dns,false) then respond({error="网关须为 192.168.31.1–254，DNS 须为有效 IPv4 地址。"},400);return end
        clean.profiles[i]={gateway=p.gateway,dns=p.dns}
    end
    local r=c.roam
    if type(r.enabled)~="boolean" or type(r.target2g)~="number" or type(r.target5g)~="number" or type(r.min_gain)~="number" or r.target2g%1~=0 or r.target5g%1~=0 or r.min_gain%1~=0 or r.target2g< -75 or r.target2g> -55 or r.target5g< -75 or r.target5g> -55 or r.min_gain<5 or r.min_gain>15 then respond({error="漫游信号须为 -75 至 -55，信号优势须为 5 至 15。"},400);return end
    clean.roam={enabled=r.enabled,target2g=r.target2g,target5g=r.target5g,min_gain=r.min_gain}
    local fs=require("nixio.fs")
    if not fs.mkdir("/tmp/mesh-gateway-save.lock") then respond({error="另一项设置正在保存，请稍后重试。"},409);return end
    local old=read(base.."/config.json")
    if old then local existing=json.decode(old);clean.mesh_nodes=existing and existing.mesh_nodes end
    local new=base.."/config.json.new"
    local f=io.open(new,"w")
    if not f then fs.rmdir("/tmp/mesh-gateway-save.lock");respond({error="无法写入插件目录。"},500);return end
    f:write(json.encode(clean));f:close();fs.chmod(new,"600")
    local renamed=os.rename(new,base.."/config.json")
    local result=renamed and os.execute(base.."/service.sh apply > /tmp/mesh-gateway-apply.log 2>&1") or -1
    if result~=0 then
        if old then local b=io.open(new,"w");if b then b:write(old);b:close();os.rename(new,base.."/config.json");os.execute(base.."/service.sh apply >> /tmp/mesh-gateway-apply.log 2>&1") end end
        fs.rmdir("/tmp/mesh-gateway-save.lock");respond({error="应用失败，已恢复之前的配置。"},500);return
    end
    fs.rmdir("/tmp/mesh-gateway-save.lock")
    respond({ok=true,message="已保存。Wi-Fi 网关和 DNS 在客户端重新获取 DHCP 后生效。"})
end
