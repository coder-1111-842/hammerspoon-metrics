top -l 2 -n 0 -s 1 | grep "CPU usage" | tail -1 | awk '{gsub("%","",$3); gsub("%","",$5); print $3+$5}'
