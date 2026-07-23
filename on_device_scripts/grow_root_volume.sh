sudo -v
echo ',+,' | sudo sfdisk -N2 --no-reread /dev/mmcblk1
sudo partprobe /dev/mmcblk1
sudo resize2fs /dev/mmcblk1p2
df -h /
