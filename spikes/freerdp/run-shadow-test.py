# freerdp-shadow-cli (NLA/NTLM, base SAM) : mauvais puis bon mot de passe. ATTENTION : le bon mot de passe capture
# reellement l'ecran du Mac (ScreenCaptureKit) ; supprimer la capture ensuite. SAM : winpr-hash -u spike -p <mdp> -f sam > $W/shadow/SAM
import socket,subprocess,time,os
W=os.environ.get('W',os.path.expanduser('~/.hermes/cache/scratch/freerdp'))
s=socket.socket();s.bind(("127.0.0.1",0));port=s.getsockname()[1];s.close()
srv=subprocess.Popen([W+'/install/bin/freerdp-shadow-cli',f'/port:{port}','/bind-address:127.0.0.1',f'/sam-file:{W}/shadow/SAM'],cwd=W+'/shadow',stdout=open(W+'/shadow/srv.log','w'),stderr=subprocess.STDOUT)
time.sleep(2); print('port',port,'alive',srv.poll() is None)
try:
    for pw in ('Wrong-Pass-9','Right-Pass-1'):
        r=subprocess.run([W+'/'+os.environ.get('BIN','rdpshot-arm64'),'127.0.0.1',str(port),'spike',pw,W+'/shadow/nla.png','12','1024x768','nla'],capture_output=True,text=True,timeout=40)
        print('PW',pw[:5],'rc',r.returncode); print([l for l in r.stdout.splitlines() if 'RESULT' in l or 'spike' in l])
        print('\n'.join(l[-200:] for l in r.stderr.splitlines() if ('ERROR' in l or 'spike' in l or 'NLA' in l or 'tls' in l.lower()) )[:2500])
finally:
    srv.terminate()
print(open(W+'/shadow/srv.log').read()[-1500:])
