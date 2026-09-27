import socket, threading, re, uuid, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
IMG=open(sys.argv[1],'rb').read()
ADF_PAGES=int(sys.argv[2]) if len(sys.argv)>2 else 3
DEV="urn:uuid:11111111-2222-3333-4444-555555555555"
def env(action, body):
    return f'''<?xml version="1.0"?><s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:a="http://schemas.xmlsoap.org/ws/2004/08/addressing" xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery" xmlns:x="http://schemas.xmlsoap.org/ws/2004/09/mex" xmlns:p="http://schemas.xmlsoap.org/ws/2006/02/devprof" xmlns:sc="http://schemas.microsoft.com/windows/2006/08/wdp/scan"><s:Header><a:Action>{action}</a:Action><a:MessageID>urn:uuid:{uuid.uuid4()}</a:MessageID></s:Header><s:Body>{body}</s:Body></s:Envelope>'''
def udp():
    s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind(("127.0.0.1",3702))
    while True:
        d,a=s.recvfrom(65535)
        if b"Probe" not in d: continue
        r=env("http://schemas.xmlsoap.org/ws/2005/04/discovery/ProbeMatches",f"<d:ProbeMatches><d:ProbeMatch><a:EndpointReference><a:Address>{DEV}</a:Address></a:EndpointReference><d:Types>wprt:PrintDeviceType wscn:ScanDeviceType</d:Types><d:XAddrs>http://127.0.0.1:5357/{DEV[9:]}</d:XAddrs><d:MetadataVersion>1</d:MetadataVersion></d:ProbeMatch></d:ProbeMatches>")
        s.sendto(r.encode(),a)
state={"left":0,"src":""}
class H(BaseHTTPRequestHandler):
    def log_message(self,*a): pass
    def send(self,code,body,ct="application/soap+xml"):
        self.send_response(code); self.send_header("Content-Type",ct); self.send_header("Content-Length",str(len(body))); self.end_headers(); self.wfile.write(body)
    def fault(self,sub):
        self.send(500,env("http://schemas.xmlsoap.org/ws/2004/08/addressing/fault",f"<s:Fault><s:Code><s:Value>s:Sender</s:Value><s:Subcode><s:Value>sc:{sub}</s:Value></s:Subcode></s:Code><s:Reason><s:Text xml:lang='en'>{sub}</s:Text></s:Reason></s:Fault>").encode())
    def do_POST(self):
        b=self.rfile.read(int(self.headers['Content-Length'])).decode()
        act=re.search(r"Action>([^<]+)<",b).group(1)
        print("<-",act.split('/')[-1], flush=True)
        if act.endswith("transfer/Get"):
            self.send(200,env("GetResponse",f"<x:Metadata><x:MetadataSection Dialect='http://schemas.xmlsoap.org/ws/2006/02/devprof/ThisModel'><p:ThisModel><p:Manufacturer>Dell</p:Manufacturer><p:ModelName>C2665dnf Color MFP</p:ModelName></p:ThisModel></x:MetadataSection><x:MetadataSection Dialect='http://schemas.xmlsoap.org/ws/2006/02/devprof/ThisDevice'><p:ThisDevice><p:FriendlyName>Dell C2665dnf (Mock)</p:FriendlyName></p:ThisDevice></x:MetadataSection><x:MetadataSection Dialect='http://schemas.xmlsoap.org/ws/2006/02/devprof/Relationship'><p:Relationship><p:Hosted><a:EndpointReference><a:Address>http://127.0.0.1:5357/scan</a:Address></a:EndpointReference><p:Types>wscn:ScannerServiceType</p:Types></p:Hosted></p:Relationship></x:MetadataSection></x:Metadata>").encode())
        elif act.endswith("GetScannerElements"):
            src='''<sc:{p}Resolutions><sc:Widths><sc:Width>150</sc:Width><sc:Width>300</sc:Width><sc:Width>600</sc:Width></sc:Widths><sc:Heights><sc:Height>150</sc:Height></sc:Heights></sc:{p}Resolutions><sc:{p}Color><sc:ColorEntry>RGB24</sc:ColorEntry><sc:ColorEntry>Grayscale8</sc:ColorEntry></sc:{p}Color><sc:{p}MaximumSize><sc:Width>8500</sc:Width><sc:Height>14000</sc:Height></sc:{p}MaximumSize>'''
            self.send(200,env("GetScannerElementsResponse",f"<sc:GetScannerElementsResponse><sc:ScannerElements><sc:ElementData Name='sc:ScannerConfiguration' Valid='true'><sc:ScannerConfiguration><sc:DeviceSettings><sc:FormatsSupported><sc:FormatValue>jfif</sc:FormatValue><sc:FormatValue>dib</sc:FormatValue></sc:FormatsSupported></sc:DeviceSettings><sc:Platen>{src.format(p='Platen')}</sc:Platen><sc:ADF><sc:ADFSupportsDuplex>true</sc:ADFSupportsDuplex><sc:ADFFront>{src.format(p='ADF')}</sc:ADFFront></sc:ADF></sc:ScannerConfiguration></sc:ElementData></sc:ScannerElements></sc:GetScannerElementsResponse>").encode())
        elif act.endswith("CreateScanJob"):
            src=re.search(r"InputSource>([^<]+)<",b).group(1); state["src"]=src
            state["left"]=1 if src=="Platen" else ADF_PAGES
            self.send(200,env("CreateScanJobResponse","<sc:CreateScanJobResponse><sc:JobId>42</sc:JobId><sc:JobToken>tok-42</sc:JobToken></sc:CreateScanJobResponse>").encode())
        elif act.endswith("RetrieveImage"):
            if state["left"]<=0: return self.fault("ClientErrorNoImagesAvailable")
            state["left"]-=1
            bd="uuid:"+str(uuid.uuid4())
            soap=env("RetrieveImageResponse","<sc:RetrieveImageResponse><sc:ScanData><xop:Include xmlns:xop='http://www.w3.org/2004/08/xop/include' href='cid:img'/></sc:ScanData></sc:RetrieveImageResponse>").encode()
            body=(f"--{bd}\r\nContent-Type: application/xop+xml; type=\"application/soap+xml\"; charset=utf-8\r\nContent-ID: <soap>\r\n\r\n").encode()+soap+(f"\r\n--{bd}\r\nContent-Type: application/binary\r\nContent-ID: <img>\r\n\r\n").encode()+IMG+f"\r\n--{bd}--\r\n".encode()
            self.send(200,body,f'multipart/related; type="application/xop+xml"; boundary="{bd}"; start="<soap>"; start-info="application/soap+xml"')
        elif act.endswith("CancelJob"):
            self.send(200,env("CancelJobResponse","<sc:CancelJobResponse/>").encode())
threading.Thread(target=udp,daemon=True).start()
HTTPServer(("127.0.0.1",5357),H).serve_forever()
