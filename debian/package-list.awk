# Generate package list from control file.

BEGIN {
  count = 1
  flag = 0
}

# This find all the dependencies, also build them if needed, but stop at
# the first stanza (for example, Descriptions, or Conflicts).
/^(Build-Depends|Depends):/,/^Description:/ {
    if (gsub("^Depends:", "") || gsub("^Build-Depends:","")) { flag = 1 }
    if ($0 !~ /^[ \t]/) { flag = 0 }    # stop at the first stanza
    if (flag == 0) next
    split($0, list, ",");
    for (i in list) {
        if (length(list[i]) > 0) {
            gsub("\(.+\)", "", list[i])
            # let's make sure we are not adding packages that we should
            # create here (ie appscale-*)
            if (list[i] ~ /appscale-/) { next }
            packages[count] = list[i]
            count += 1
        }
    }
}

END {
    for (i in packages)
	printf("%s ", packages[i])
}
