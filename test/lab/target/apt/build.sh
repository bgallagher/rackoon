#!/bin/sh
# Two tiny packages, each installed at 1.0 with 1.1 waiting: rackoon-lab-tool in archive "lab", rackoon-lab-secure in
# "lab-security" (Rackoon counts a package as security when a suite ends in -security). Ubuntu's own archives are
# removed afterwards, so `apt-get update` in the lab never reaches the internet.
set -eu
mkpkg() { # name version dir
  d=$(mktemp -d); mkdir -p "$d/DEBIAN"
  printf 'Package: %s\nVersion: %s\nArchitecture: all\nMaintainer: Rackoon lab <lab@invalid>\nDescription: Rackoon lab test package\n' "$1" "$2" > "$d/DEBIAN/control"
  mkdir -p "$3"; dpkg-deb --build "$d" "$3/$1_$2_all.deb" >/dev/null; rm -rf "$d"
}
mkpkg rackoon-lab-tool 1.0 /lab/apt/installed
mkpkg rackoon-lab-secure 1.0 /lab/apt/installed
dpkg -i /lab/apt/installed/*.deb >/dev/null
for archive in lab lab-security; do
  dir=/srv/apt/$archive
  case $archive in lab) mkpkg rackoon-lab-tool 1.1 $dir ;; *) mkpkg rackoon-lab-secure 1.1 $dir ;; esac
  (cd $dir && apt-ftparchive packages . > Packages \
     && apt-ftparchive -o APT::FTPArchive::Release::Suite=$archive -o APT::FTPArchive::Release::Archive=$archive \
          -o APT::FTPArchive::Release::Codename=$archive release . > Release)
  echo "deb [trusted=yes] file:$dir ./" > /etc/apt/sources.list.d/$archive.list
done
rm -f /etc/apt/sources.list.d/ubuntu.sources /etc/apt/sources.list
apt-get update >/dev/null
