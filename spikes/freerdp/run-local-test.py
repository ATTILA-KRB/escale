# Serveur d'exemple sfreerdp-server (TLS, sans NLA) + client rdpshot : capture bout en bout, port libre dynamique.
# Prerequis : server.crt/server.key et test_icon.* dans $W/srv (voir REPORT.md). BIN=rdpshot-arm64|rdpshot-x86_64.
import socket,subprocess,time,os,os,sys
W=os.environ.get('W',os.path.expanduser('~/.hermes/cache/scratch/freerdp'))
s=socket.socket();s.bind(("127.0.0.1",0));port=s.getsockname()[1];s.close()
srv=subprocess.Popen([W+'/install/bin/sfreerdp-server',f'--port={port}','--cert=server.crt','--key=server.key'],cwd=W+'/srv',stdout=open(W+'/srv/srv.log','w'),stderr=subprocess.STDOUT)
time.sleep(2)
print('port',port,'srv alive',srv.poll() is None)
try:
    r=subprocess.run([W+'/'+os.environ.get('BIN','rdpshot-arm64'),'127.0.0.1',str(port),'test','test',W+'/local.png','15','1024x768','tls'],capture_output=True,text=True,timeout=40)
    print('rc',r.returncode); print(r.stdout); print(r.stderr[-1500:])
finally:
    srv.terminate()
print(open(W+'/srv/srv.log').read()[-800:])
