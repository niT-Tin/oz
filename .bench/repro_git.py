import os, subprocess, time, select, fcntl, termios, struct, shutil

d = '/tmp/oz_repro_git'
shutil.rmtree(d, ignore_errors=True)
os.makedirs(d)
def run(*argv, cwd=d):
    subprocess.run(argv, cwd=cwd, check=True, capture_output=True)
run('git','init','-q','-b','main')
run('git','config','user.email','e2e@test')
run('git','config','user.name','E2E Tester')
with open(os.path.join(d,'a.txt'),'w') as f:
    for n in range(1,21): f.write(f"line{n}\n")
run('git','add','a.txt'); run('git','commit','-q','-m','init')
# modify: lines 3-5 -> CHANGED, delete tail after line 16, add NEW at 17-19
content = []
for n in range(1,21):
    if 3 <= n <= 5: content.append("CHANGED\n")
    elif n == 16: content.append("line16\n")
    elif n >= 17: content.append(f"NEW{n}\n")
    else: content.append(f"line{n}\n")
with open(os.path.join(d,'a.txt'),'w') as f:
    f.writelines(content)

master, slave = os.openpty()
fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 120, 0, 0))
os.set_blocking(master, False)
env = dict(os.environ, TERM='xterm-256color')
def pre():
    os.setsid(); fcntl.ioctl(0, termios.TIOCSCTTY, 0)
p = subprocess.Popen(['/home/leoz/sources/oz/zig-out/bin/oz','a.txt'], cwd=d, stdin=slave, stdout=slave, stderr=slave, preexec_fn=pre, env=env, close_fds=True)
os.close(slave)

def wait_for(needle, timeout):
    buf = b''
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        r,_,_ = select.select([master],[],[],0.2)
        if r:
            try: c = os.read(master, 65536)
            except OSError: break
            if not c: break
            buf += c
        if needle.encode() in buf:
            return True, buf
    return False, buf

ok, buf = wait_for("E2E Tester, ", 8)
print("GHOST APPEARED:", ok)
print("last bytes:", repr(buf[-300:]))
try: os.killpg(p.pid, 15)
except: pass
