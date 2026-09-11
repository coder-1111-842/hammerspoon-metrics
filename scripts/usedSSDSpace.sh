total=$(diskutil info / | awk -F'[()]' '/Container Total Space/ {print $2}' | tr -dc '0-9')
free=$(diskutil info / | awk -F'[()]' '/Container Free Space/  {print $2}' | tr -dc '0-9')
echo "scale=1; ($total - $free) * 100 / $total" | bc
