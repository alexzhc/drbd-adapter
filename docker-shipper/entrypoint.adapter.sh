#!/bin/bash -x
## Maintainer Alex Zheng <alex.zheng@daocloud.io>
## This is a wrapper scripts to have drbd9 containers automatically adapt host distros

## Check if image matches os type
which lbdisttool.py

image_dist="$(lbdisttool.py -l | awk -F'.' '{print $1}' )"
host_dist="$(lbdisttool.py -l --os-release /etc/host-release | awk -F'.' '{print $1}' )"

# For Kylin v10, use RHEL 8 base for now
if [ -z $host_dist ] \
   && uname -r | grep -i '.ky10.' \
   && grep -iw kylin /etc/host-release; then
   echo "Host distro is Kylin V10"
   host_dist=rhel8
fi

# Gracefully exit for distro mismatch, so that next initContainer may start
if [[ $host_dist != $image_dist ]]; then 
   echo "Image type does not match OS type, skip !" 
   exit 0
fi

## Unload current drbd modules from kernel if it is lower than the target version 
# (only possible if no [drbd_xxx] process is running)
RUNNING_DRBD_VERSION=$( cat /proc/drbd | awk '/^version:/ {print $2}' )

if [ -z $RUNNING_DRBD_VERSION ]; then
   echo "No DRBD Module is loaded"
elif [[ $RUNNING_DRBD_VERSION == $DRBD_VERSION ]] || \
     [[ $( printf "$RUNNING_DRBD_VERSION\n$DRBD_VERSION" | sort -V | tail -1 ) != $DRBD_VERSION ]]
then
   echo "The loaded DRBD module version is already $RUNNING_DRBD_VERSION"
else 
   echo "The loaded DRBD module version $RUNNING_DRBD_VERSION is lower than $DRBD_VERSION"
   if [[ $LB_UPGRADE == 'yes' ]]; then
      for i in drbd_transport_tcp drbd; do
         if lsmod | grep -w $i; then
            rmmod $i || true
         fi
      done
   fi
fi

## Main Logic
# If no shipped module is found, then compile from source
if LB_HOW=shipped_modules bash -x /entry.sh; then
   echo "Successfully loaded shipped module"
elif LB_HOW=compile bash -x /entry.sh; then
   echo "Successfully loaded compiled module"
fi

# Drop modules to the host so it can independently load from OS
if [[ $LB_DROP == yes ]]; then

   # drop modules
   if [[ $host_dist =~ rhel ]]; then
      KODIR="/lib/modules/$(uname -r)/extra/drbd"
   elif [[ $host_dist =~ bionic|focal|jammy ]]; then
      KODIR="/lib/modules/$(uname -r)/updates/dkms/drbd"
   else
      KODIR="/lib/modules/$(uname -r)/drbd"
   fi 
   mkdir -vp "$KODIR"
   cp -vf /tmp/ko/*.ko "${KODIR}/"

   # register modules
   depmod -a

   # onboot load modules 
   cp -vf /pkgs/drbd.modules-load.conf /etc/modules-load.d/drbd.conf

   # drop drbd utils
   cp -vf /pkgs/drbd-utils/* /usr-local-bin/
fi