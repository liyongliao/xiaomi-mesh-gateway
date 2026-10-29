local base="/userdisk/mesh-gateway"
local json=require("luci.json")
local function read(p) local f=assert(io.open(p,"r"));local b=f:read("*a");f:close();return b end
local function write(p,b) local f=assert(io.open(p,"w"));assert(f:write(b));f:close() end
if arg[1]=="prepare" then
    local c=assert(json.decode(read(base.."/config.json")))
    local options={}
    for _,i in ipairs({"wl0","wl1","wl2"}) do
        local p=assert(c.profiles[i]);assert(p.gateway:match("^192%.168%.31%.%d+$"));assert(p.dns:match("^[%d%.]+$"))
        if c.enabled then
            options[#options+1]="tag:meshgw_"..i..",3,"..p.gateway
            options[#options+1]="tag:meshgw_"..i..",6,"..p.dns
        end
    end
    write("/tmp/mesh-gateway-options.new",table.concat(options,"\n").."\n")
    local roam=read(base.."/backup/roam.conf")
    if c.roam.enabled then
        local values={DownlinkTargetRSSIThreshold_W2=c.roam.target2g,DownlinkTargetRSSIThreshold_W5=c.roam.target5g,DownlinkServingRSSIThreshold_W2=c.roam.target2g,DownlinkServingRSSIThreshold_W5=c.roam.target5g,APSteerToPeerMinRSSIIncThreshold=c.roam.min_gain}
        for k,v in pairs(values) do
            local count;roam,count=roam:gsub("("..k.."=)[^\r\n]+","%1"..tostring(v));assert(count==1,"Unknown firmware roaming config: "..k)
        end
    end
    write("/tmp/mesh-gateway-roam.new",roam)
elseif arg[1]=="header" then
    local s=read("/usr/lib/lua/luci/view/web/inc/header.htm")
    local link='<a href="<%=luci.dispatcher.build_url("web","prosetting","mesh_gateway")%>" style="position:fixed;right:24px;bottom:24px;padding:12px 18px;background:#ff6900;color:#fff;border-radius:24px;z-index:9999;font-size:14px;box-shadow:0 4px 16px #0002">Mesh 与 Wi-Fi 分流</a>'
    write("/tmp/mesh-gateway-header.htm",s.."\n"..link.."\n")
end
