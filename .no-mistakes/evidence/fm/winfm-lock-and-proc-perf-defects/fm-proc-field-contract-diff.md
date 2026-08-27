# fm_proc_field behaviour, base commit vs HEAD, every input class

Both variants driven through the same inputs by the same harness on this host.
Value, return code and stderr are captured separately for each call.

```console
--- MSYS /proc layout, live pid ---
live pid               pid=4242     field=ppid   rc=0 value=[1] stderr=[]
live pid               pid=4242     field=pgid   rc=0 value=[4242] stderr=[]
live pid               pid=4242     field=sid    rc=0 value=[4242] stderr=[]
live pid               pid=4242     field=comm   rc=0 value=[/c/nvm4w/nodejs/node] stderr=[]
live pid               pid=4242     field=args   rc=0 value=[/c/nvm4w/nodejs/node claude.js --resume] stderr=[]
live pid               pid=4242     field=lstart rc=1 value=[] stderr=[]
--- MSYS /proc layout, pid that vanished mid-walk ---
vanished mid-walk      pid=4243     field=ppid   rc=0 value=[9] stderr=[]
vanished mid-walk      pid=4243     field=pgid   rc=1 value=[] stderr=[]
vanished mid-walk      pid=4243     field=sid    rc=1 value=[] stderr=[]
vanished mid-walk      pid=4243     field=comm   rc=1 value=[] stderr=[]
vanished mid-walk      pid=4243     field=args   rc=1 value=[] stderr=[]
--- rejected input ---
rejected input         pid=         field=ppid   rc=1 value=[] stderr=[]
rejected input         pid=abc      field=ppid   rc=1 value=[] stderr=[]
rejected input         pid=-1       field=ppid   rc=1 value=[] stderr=[]
rejected input         pid=999999   field=ppid   rc=1 value=[] stderr=[]
--- ps fallback path (no MSYS /proc layout present) ---
ps fallback            pid=1        field=ppid   rc=0 value=[      0] stderr=[]
ps fallback            pid=1        field=pgid   rc=0 value=[      0] stderr=[]
ps fallback            pid=1        field=comm   rc=0 value=[init(Ubuntu-24.] stderr=[]
```

Diff of the base-commit run against the HEAD run:

```console
$ diff -u contract.v0.txt contract.v1.txt
(no output - identical across every input class)
```

The four-fork-to-zero change is invisible at the interface, which is the point:
the vanished-pid rows return 1 with empty stdout AND empty stderr on both sides,
which is what the brace group buys and what guard 1 pins.
