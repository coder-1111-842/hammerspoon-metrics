#!/usr/bin/env bash
total=$(sysctl -n hw.memsize)
pagesize=$(sysctl -n hw.pagesize)

read used_pages < <(vm_stat | awk '
  /wired down/        {w=$NF}
  /Pages active/      {a=$NF}
  /by compressor/     {c=$NF}
  END {gsub(/\./,"",w); gsub(/\./,"",a); gsub(/\./,"",c); print w+a+c}')

used=$(( used_pages * pagesize ))
echo "scale=1; $used * 100 / $total" | bc
