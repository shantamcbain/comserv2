import sys, importlib.util
spec=importlib.util.spec_from_file_location("nh", sys.argv[1]); nh=importlib.util.module_from_spec(spec); spec.loader.exec_module(nh)
def run(cur, seq, dt=3):
    st={}; t=0
    for v in seq:
        cur, st = nh.stabilize(v, cur, t, st); t+=dt
    return cur
ok=True
def chk(name, got, exp):
    global ok; print(("ok   " if got==exp else "FAIL ")+name, got); ok &= got==exp
chk("flap from 93 stays 93", run(93,[100,93]*10), 93)
chk("flap from 100 settles to 93", run(100,[93,100]*10+[93]), 93)
chk("real jump 93->100 accepted on 2nd read", run(93,[100,100],dt=15), 100)
chk("single spike ignored", run(93,[100]), 93)
chk("small move accepted", run(93,[95]), 95)
chk("weekly reset drop accepted on 2nd read", run(93,[2,2],dt=15), 2)
sys.exit(0 if ok else 1)
