#!/bin/bash

# clear index.markdown
echo "---" > index.markdown
echo "layout: default" >> index.markdown
echo "---" >> index.markdown
echo "" >> index.markdown
echo "# Posts" >> index.markdown
echo "" >> index.markdown

# for every markdown file in _posts
# generate a link
cd _posts
for file in *.markdown; do
    # get date
    date=$(echo $file | awk -F- '{ print $3"-"$2"-"$1 }')
    
    # get title (from 3rd line)
    title=$(head -n 3 $file | tail -n 1 | awk -F\" '{ print $2 }' | sed 's/\"//g')

    # get filename without ext
    name=$(echo $file | sed 's/.markdown//g')
    
    # echo link
    echo "[$date] [$title](/htb-writeups{% post_url $name %})" >> ../index.markdown
    echo "" >> ../index.markdown
done
