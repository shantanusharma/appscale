#!/bin/bash
#
# author: g@appscale.com
#
# Enable the datastore viewer and reload nginx.

ALLOW=""
APPS_ID=""
IP="all"
VIEWER_PORT="8099"

usage() {
        echo
        echo "Usage: $0 [app-id ...]"
        echo
        echo "Enable the dataviewer for app-id. If no app-id is specified, enable the viewer for all apps."
        echo "WARNING: the datastore viewer is not protected! Anyone can browse your data."
        echo "WARNING: restricting by IP should be used judiciously."
        echo
        echo "Options:"
        echo "     -h        this message"
        echo "     -i <IP>   allow connections only from this IP (default is open)"
        echo
}

while [ $# -gt 0 ]; do
        if [ "$1" = "-h" -o "$1" = "-help" -o "$1" = "--help" ]; then
                usage
                exit 1
        fi
	if [ -n "$1" -a "$1" = "-i" ]; then
		if [ -n "$2" ]; then
			IP="$2"
			ALLOW="allow $IP; 
      deny all;"
			shift;shift
			continue
		else
			usage
			exit 1
		fi
	fi
        if [ -n "$1" ]; then
                APPS_ID="$APPS_ID $1"
                shift
                continue
        fi
done

# Sanity checks.
if [ ! -e /etc/nginx/sites-enabled ]; then
        echo "ERROR: Cannot find nginx configurations. Is this an AppScale deployment?"
        exit 1
fi

# Get the list of running applications, and corresponding ports.
ps ax | grep appserver | grep -Ev '(grep|appscaledashboard)' | grep -- '--admin_port' | sed 's;.*--admin_port \([0-9]*\).*/var/apps/\(.*\)/app .*;\1 \2;g' | sort -ru | while read port app_id; do
        # Enable only for specified apps.
        if [ -n "$APPS_ID" ]; then
                found="no"
                for x in $APPS_ID ; do
                        if [ "$x" = "$app_id" ]; then
                                found="yes"
                                break
                        fi
                done
                if [ "$found" = "no" ]; then
                        continue
                fi
        fi

	let $((VIEWER_PORT += 1))

	# Do not apply if it's already there.
	if grep "datastore_viewer" /etc/nginx/sites-enabled/* > /dev/null ; then
		echo "Datastore viewer already enabled for $app_id."
		continue
	fi

	# Prepare the nginx config snippet.
	pippo="
upstream datastore_viewer_$VIEWER_PORT {
  server localhost:$port;
}
map \$scheme \$ssl {
    default off;
    https on;
}

server {
    listen $VIEWER_PORT;
    server_name datastore_viewer_server;
    location / {
      $ALLOW
      proxy_pass http://datastore_viewer_$VIEWER_PORT;
    }
}
"
	if [ -e /etc/nginx/sites-enabled/${app_id}.conf ]; then
		cp /etc/nginx/sites-enabled/${app_id}.conf /tmp
		echo "$pippo" >> /etc/nginx/sites-enabled/${app_id}.conf
		echo "Datastore viewer enabled for $app_id at http://$(cat /etc/appscale/my_public_ip):$VIEWER_PORT. Allowed IP: $IP."
		service nginx reload
	else
		echo "Cannot find configuration for ${app_id}."
	fi
done
