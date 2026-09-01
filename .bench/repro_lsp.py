import os, subprocess, time, select, fcntl, termios, struct

def spawn(argv, env_extra):
    master, slave = os.openpty()
    fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 120, 0, 0))
    os.set_blocking(master, False)
    env = dict(os.environ, TERM='xterm-256color', **env_extra)
    def pre():
        os.setsid(); fcntl.ioctl(0, termios.TIOCSCTTY, 0)
    p = subprocess.Popen(argv, stdin=slave, stdout=slave, stderr=slave, preexec_fn=pre, env=env, close_fds=True)
    os.close(slave)
    return master, p

def readall(master, secs):
    out = b''
    end = time.monotonic() + secs
    while time.monotonic() < end:
        r,_,_ = select.select([master],[],[],0.05)
        if not r: continue
        try:
            c = os.read(master, 65536)
        except OSError:
            break
        if not c: break
        out += c
    return out

# fixture
with open('/tmp/oz_repro.zig','w') as f:
    f.write("const a = 1;\nconst b = 2;\nmo")

try: os.remove('.bench/mock-debug.log')
except: pass

m, p = spawn(['zig-out/bin/oz', '/tmp/oz_repro.zig'],
             {'OZ_LSP_CMD': os.path.abspath('.bench/mock_wrap.sh')})
readall(m, 2.0)
os.write(m, b'jjAx')
time.sleep(3)
out = readall(m, 1.0)
os.killpg(p.pid, 15)
try: p.wait(timeout=2)
except: os.killpg(p.pid, 9)

text = out.decode('utf-8', 'replace')
print("=== screen tail ===")
print(text[-800:])
print("=== mock log ===")
try:
    print(open('.bench/mock-debug.log').read()[-3000:])
except FileNotFoundError:
    print("(no mock log)")
