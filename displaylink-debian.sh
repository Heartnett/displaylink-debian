#!/bin/bash
#
# displaylink-debian:
# DisplayLink driver installer for Debian and Ubuntu based Linux distributions: Debian, Ubuntu, Elementary OS,
# Mint, Kali, Deepin and more! Full list of all supported platforms: http://bit.ly/2zrwz2u
#
# DisplayLink driver installer for Debian GNU/Linux, Ubuntu, Elementary OS, Mint, Kali, Deepin and more! Full list of all supported Linux distributions
#
# Blog post: http://foolcontrol.org/?p=1777
#
# Copyleft: Adnan Hodzic <adnan@hodzic.org>
# License: GPLv3

# Bash Strict Mode
set -eu
# set -o pipefail # TODO: Some code still fails this check, fix before enabling.
IFS=$'\n\t'

kernel_check="$(uname -r | grep -Eo '^[0-9]+\.[0-9]+')"

function ver2int {
	echo "$@" | awk -F "." '{ printf("%03d%03d%03d\n", $1,$2,$3); }';
}

# Get latest versions
versions=$(wget -q -O - https://www.synaptics.com/products/displaylink-graphics/downloads/ubuntu | grep "<p>Release: " | head -n 2 | perl -pe '($_)=/([0-9]+([.][0-9]+)+(\ Beta)*)/; exit if $. > 1;')
# if versions contains "Beta", try to download previous version
if [[ $versions =~ Beta ]]; then
    version=$(wget -q -O - https://www.synaptics.com/products/displaylink-graphics/downloads/ubuntu | grep "<p>Release: " | head -n 2 | perl -pe '($_)=/([0-9]+([.][0-9]+)+(?!\ Beta))/; exit if $. > 1;')
    dlurl="https://www.synaptics.com/$(wget -q -O - https://www.synaptics.com/products/displaylink-graphics/downloads/ubuntu | grep -B 2 $version'-Release' | perl -pe '($_)=/<a href="\/([^"]+)"[^>]+class="download-link"/')"
    driver_url="https://www.synaptics.com/$(wget -q -O - ${dlurl} | grep '<a class="no-link"' | head -n 1 | perl -pe '($_)=/href="\/([^"]+)"/')"
else
    version=`wget -q -O - https://www.synaptics.com/products/displaylink-graphics/downloads/ubuntu | grep "<p>Release: " | head -n 1 | perl -pe '($_)=/([0-9]+([.][0-9]+)+)/; exit if $. > 1;'`
    dlurl="https://www.synaptics.com/$(wget -q -O - https://www.synaptics.com/products/displaylink-graphics/downloads/ubuntu | grep -B 2 $version'-Release' | perl -pe '($_)=/<a href="\/([^"]+)"[^>]+class="download-link"/')"
    driver_url="https://www.synaptics.com/$(wget -q -O - ${dlurl} | grep '<a class="no-link"' | head -n 1 | perl -pe '($_)=/href="\/([^"]+)"/')"
fi
driver_dir=$version
dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )/" && pwd )"
resourcesDir="$(pwd)/resources/"

# globalvars
lsb="$(lsb_release -is)"
codename="$(lsb_release -cs)"
platform="$(lsb_release -ics | sed '$!s/$/ /' | tr -d '\n')"
kernel="$(uname -r)"
xorg_config_displaylink="/etc/X11/xorg.conf.d/20-displaylink.conf"
blacklist="/etc/modprobe.d/blacklist.conf"
sys_driver_version="$(ls /usr/src/ | grep "evdi" | cut -d "-" -f2)"
vga_info="$(lspci | grep -oP '(?<=VGA compatible controller: ).*')" || :
vga_info_3d="$(lspci | grep -i '3d controller' | sed 's/^.*: //')"
graphics_vendor="$(lspci -nnk | grep -i vga -A3 | grep 'in use' | cut -d ':' -f2 | sed 's/ //g')"
graphics_subcard="$(lspci -nnk | grep -i vga -A3 | grep Subsystem | cut -d ' ' -f5)"
providers="$(xrandr --listproviders)"
xorg_vcheck="$(dpkg -l | grep "ii  xserver-xorg-core" | awk '{print $3}' | sed 's/[^,:]*://g')"
min_xorg=1.18.3
newgen_xorg=1.19.6
init_script='displaylink.sh'
evdi_modprobe='/etc/modules-load.d/evdi.conf'
kconfig_file="/lib/modules/$kernel/build/Kconfig"

# Using modules-load.d should always be preferred to 'modprobe evdi' in start
# command

# writes a text separator line to the terminal
function separator() {
	echo -e "\n-------------------------------------------------------------------"
}

# invalid option error message
function invalid_option() {
	separator
	echo -e "\nInvalid option specified."
	separator
	read -rsn1 -p 'Enter any key to continue'
	echo ''

	# exit the script when an invalid
	# option is specified by the user
	exit 1
}

# checks if the script is executed by root user
function root_check() {
	# perform root check and exit function early,
	# if the script is executed by root user
	[ $EUID -eq 0 ] && return

	separator
	echo -e "\nScript must be executed as root user (i.e: 'sudo $0')."
	separator
	exit 1
}

# list all xorg related configs
function get_xconfig_list() {
	local x11_etc='/etc/X11/'

	# No directory found
	if [ ! -d "$x11_etc" ]; then
		echo 'X11 configs: None'
		return 0
	fi

	if [ "$(find "$x11_etc" -maxdepth 2 -name "*.conf" | wc -l)" -gt 0 ]; then
		find "$x11_etc" -type f -name "*.conf" | xargs echo 'X11 configs:'
	fi
}

# checks if script dependencies are installed
# automatically installs missing script dependencies
function dependencies_check() {
	echo -e "\nChecking dependencies...\n"

	local dpkg_arch="$(dpkg --print-architecture)"

	# script dependencies
	local dependencies=(
		'unzip'
		"linux-headers-$(uname -r)"
		'dkms'
		'lsb-release'
		'linux-source'
		'x11-xserver-utils'
		'wget'
		"libdrm-dev:$dpkg_arch"
		"libelf-dev:$dpkg_arch"
		'git'
		'pciutils'
		'build-essential'
	)

	for dependency in "${dependencies[@]}"; do
		# skip dependency installation if dependency is already present
		if dpkg -s "$dependency" | grep -q 'Status: install ok installed'; then
			continue
		fi

		echo "installing dependency: $dependency"

		if ! apt-get install -q=2 -y "$dependency"; then
			echo "$dependency installation failed.  Aborting."
			exit 1
		fi
	done
}

# checks if the script is running on a supported 
function distro_check() {
	separator
	# check for Red Hat based distro
	if [ -f /etc/redhat-release ]; then
		echo -e "\nRed Hat based linux distributions are not supported."
		separator
		exit 1
	fi

	# confirm dependencies are in place
	dependencies_check

	# supported Debian based linux distributions
	local -r supported_distributions=(
		'BunsenLabs'
		'Bunsenlabs'
		'Debian'
		'Deepin'
		'Devuan'
		'elementary OS'
		'Kali'
		'MX'
		'Neon'
		'Nitrux'
		'Parrot'
		'Pop'
		'PureOS'
		'Ubuntu'
		'Uos' # Deepin alternative LSB string
		'Zorin'
	)

	if [[ "${supported_distributions[*]/$lsb/}" != "${supported_distributions[*]}" ]] || [[ "$lsb" =~ (elementary|Linuxmint) ]]; then
		echo -e "\nPlatform requirements satisfied, proceeding ..."
	else
		cat <<_UNSUPPORTED_PLATFORM_MESSAGE_

---------------------------------------------------------------

Unsuported platform: $platform
Full list of all supported platforms: http://bit.ly/2zrwz2u
This tool is Open Source and feel free to extend it
GitHub repo: https://github.com/AdnanHodzic/displaylink-debian/

---------------------------------------------------------------

_UNSUPPORTED_PLATFORM_MESSAGE_
		exit 1
	fi
}

# checks if the Kconfig file exists
function pre_install() {
	if [ -f "$kconfig_file" ]; then
		kconfig_exists=true
	else
		kconfig_exists=false
		touch "$kconfig_file"
	fi
}

# retrieves the init system name
function get_init_system() {
	local init_system=''

	case "$lsb" in
		'Devuan')
			init_system='sysvinit'
			;;

		'elementary OS')
			[ "$codename" == "freya" ] && init_system='upstart'
			;;

		'Ubuntu')
			[ "$codename" == 'trusty' ] && init_system='upstart'
			;;
	esac

	if [ -z "$init_system" ] && [[ "$lsb" =~ elementary ]] && [ "$codename" == "freya" ]; then
		init_system='upstart'
	fi

	
	[ -z "$init_system" ] && init_system='systemd'

	echo "$init_system"
}

# checks if the Displaylink service is running
function displaylink_service_check () {	
	case "$(get_init_system)" in
		'systemd')
			systemctl is-active --quiet displaylink-driver.service && echo 'up and running'
			;;

		'sysvinit')
			"/etc/init.d/${init_script}" status
			;;
	esac
}

# performs post-installation clean-up by removing obsolete/redundant files which can only hamper reinstalls
function clean_up() {
	separator
	echo -e "\nPerforming clean-up"

	local zip_file="DisplayLink_Ubuntu_$version.zip"

	# go back to displaylink-debian
	cd - &> /dev/null

	if [ -f "$zip_file" ]; then
		echo "Removing redundant: '$zip_file' file"
		rm "$zip_file"
	fi

	if [ -d "$driver_dir" ]; then
		echo "Removing redundant: '$driver_dir' directory"
		rm -r "$driver_dir"
	fi
}

# called when the driver setup is complete
function setup_complete() {
	local default='Y'
	local reboot_choice="$default"

	read -p "Reboot now? [Y/n] " reboot_choice
	reboot_choice="${reboot_choice:-$default}"

	case "$reboot_choice" in
		'y'|'Y')
			echo "Rebooting ..."
			reboot
			;;

		'n'|'N')
			echo -e '\nReboot postponed, changes will not be applied until reboot.'
			;;

		*)
			invalid_option
			;;
	esac
}

# downloads the DisplayLink driver
function download() {
	local default='y'

	echo -en "\nPlease read the Software License Agreement available at: \n$dlurl\nDo you accept?: [Y/n]: "
	read accept_license_agreement
	accept_license_agreement=${accept_license_agreement:-$default}

	# exit the script if the user did not accept the software license agreement
	if [[ ! "$accept_license_agreement" =~ ^(y|Y)$ ]]; then
		echo "Can't download the driver without accepting the license agreement!"
		exit 1
	fi

	echo -e "\nDownloading DisplayLink Ubuntu driver:\n"

	# make sure file is downloaded before continuing
	if ! wget -O "DisplayLink_Ubuntu_${version}.zip" "${driver_url}"; then
		echo -e "\nUnable to download Displaylink driver\n"
		exit
	fi
}

# add udlfb to blacklist (issue #207)
function udl_block() {
	# if necessary create blacklist.conf
	[ ! -f "$blacklist" ] && touch "$blacklist"

	local -r blacklist_items=(
		'udlfb'
		'udl' # add udl to blacklist (issue #207)
	)

	for blacklist_item in "${blacklist_items[@]}"; do
		# skip if item already blacklisted
		if grep -Fxq "blacklist $blacklist_item" "$blacklist"; then
			continue
		fi

		# add item to blacklist
		echo "Adding $blacklist_item to blacklist"
		echo "blacklist $blacklist_item" >> "$blacklist"
	done
}

# installs the displaylink driver
function install() {
	separator
	download

	local displaylink_driver_dir="${driver_dir}/displaylink-driver-${version}"
    local installer_script="${displaylink_driver_dir}/displaylink-installer.sh"
	local build_dir="/lib/modules/$(uname -r)/build"

	# udlfb kernel version check
	local kernel_check="$(uname -r | grep -Eo '[0-9]+\.[0-9]+')"

	# get init system
	local init_system="$(get_init_system)"

	# prepare for installation
	# check if prior drivers have been downloaded
	if [ -d "$driver_dir" ]; then
		echo "Removing prior: '$driver_dir' directory"
		rm -r "$driver_dir"
	fi

	mkdir -p "$driver_dir"

	separator
	echo -e "\nPreparing for install\n"
	test -d "$driver_dir" && /bin/rm -Rf "$driver_dir"
	unzip -d "$driver_dir" "DisplayLink_Ubuntu_${version}.zip"
	chmod +x $driver_dir/displaylink-driver-${version}*.run
	./$driver_dir/displaylink-driver-${version}*.run --keep --noexec
	mv displaylink-driver-${version}*/ "$displaylink_driver_dir"

	# modify displaylink-installer.sh
	sed -i "s/SYSTEMINITDAEMON=unknown/SYSTEMINITDAEMON=$init_system/g" "$installer_script"

	# issue: 227
	local -r distros=(
		'BunsenLabs'
		'Bunsenlabs'
		'Debian'
		'Deepin'
		'Devuan'
		'Kali'
		'MX'
		'Uos'
	)

	if [[ "${distros[*]/$lsb/}" != "${distros[*]}" ]]; then
		sed -i 's#/lib/modules/$KVER/build/Kconfig#/lib/modules/$KVER/build/scripts/kconfig/conf#g' "$installer_script"
		ln -sf "${build_dir}/Makefile" "${build_dir}/Kconfig"
	fi

	# patch displaylink-installer.sh to prevent reboot before the script is done
	patch -Np0 "$installer_script" < "${resourcesDir}displaylink-installer.patch"

	# run displaylink install
	echo -e "\nInstalling driver version: $version\n"
	cd "$displaylink_driver_dir"
	./displaylink-installer.sh install

	# add udl/udlfb to blacklist depending on kernel version (issue #207)
	[ "$(ver2int "$kernel_check")" -ge "$(ver2int '4.14.9')" ] && udl_block
}

# issue: 204, 216
function nvidia_hashcat() {
	echo "Installing hashcat-nvidia, 'contrib non-free' must be enabled in apt sources"
	apt-get install -y hashcat-nvidia
}

# appends nvidia xrandr specific script code (partial)
function nvidia_xrandr_partial() {
	cat >> "$1" <<_NVIDIA_XRANDR_SCRIPT_

xrandr --setprovideroutputsource modesetting NVIDIA-0
xrandr --auto
_NVIDIA_XRANDR_SCRIPT_
}

# writes nvidia xrandr specific script code (full)
function nvidia_xrandr_full() {
	cat > "$1" <<_NVIDIA_XRANDR_FULL_SCRIPT_
#!/bin/sh
# Xsetup - run as root before the login dialog appears

if [ -e /sbin/prime-offload ]; then
    echo running NVIDIA Prime setup /sbin/prime-offload
    /sbin/prime-offload
fi
_NVIDIA_XRANDR_FULL_SCRIPT_

	nvidia_xrandr_partial "$1"
}

# performs nvidia specific pre-setup operations
function nvidia_pregame() {
	local xsetup_loc="/usr/share/sddm/scripts/Xsetup"

	# xorg.conf ops
	local xorg_config="/etc/x11/xorg.conf"
	local usr_xorg_config_displaylink="/usr/share/X11/xorg.conf.d/20-displaylink.conf"

	# create Xsetup file if not there + make necessary changes (issue: #201, #206)
	if [ ! -f $xsetup_loc ]; then
		echo "$xsetup_loc not found, creating"
		mkdir -p /usr/share/sddm/scripts/
		touch $xsetup_loc
		nvidia_xrandr_full "$xsetup_loc"
		chmod +x $xsetup_loc
		echo -e "Wrote changes to $xsetup_loc"
	fi

	# make necessary changes to Xsetup
	if ! grep -q "setprovideroutputsource modesetting" $xsetup_loc; then
		mv $xsetup_loc $xsetup_loc.org.bak
		echo -e "\nMade backup of: $xsetup_loc file"
		echo -e "\nLocation: ${xsetup_loc}.org.bak"
		nvidia_xrandr_partial "$xsetup_loc"
		chmod +x $xsetup_loc
		echo -e "Wrote changes to $xsetup_loc"
	fi

	# config files to backup
	local -r configs=(
		"$xorg_config"
		"$xorg_config_displaylink"
		"$usr_xorg_config_displaylink"
	)

	for config_file in "${configs[@]}"; do
		# skip if config file does not exist
		[ ! -f "$config_file" ] && continue

		# backup config file
		mv "$config_file" "${config_file}.org.bak"
		echo -e "\nMade backup of: $config_file file"
		echo -e "\nLocation: ${config_file}.org.bak"
	done
}

# amd displaylink xorg.conf
function xorg_amd() {
	cat > "$xorg_config_displaylink" <<_XORG_AMD_CONFIG_
Section "Device"
	Identifier "AMDGPU"
	Driver     "amdgpu"
	Option     "PageFlip" "false"
EndSection
_XORG_AMD_CONFIG_
}

# intel displaylink xorg.conf
function xorg_intel() {
	cat > "$xorg_config_displaylink" <<_XORG_INTEL_CONFIG_
Section "Device"
	Identifier  "Intel"
	Driver      "intel"
EndSection
_XORG_INTEL_CONFIG_
}

# modesetting displaylink xorg.conf
function xorg_modesetting() {
	cat > "$xorg_config_displaylink" <<_XORG_MODESETTING_CONFIG_
Section "Device"
	Identifier  "DisplayLink"
	Driver      "modesetting"
	Option      "PageFlip" "false"
EndSection
_XORG_MODESETTING_CONFIG_
}

# modesetting displaylink xorg.conf
function xorg_modesetting_newgen() {
	cat > "$xorg_config_displaylink" <<_XORG_EVDI_CONFIG_
Section "OutputClass"
	Identifier  "DisplayLink"
	MatchDriver "evdi"
	Driver      "modesetting"
	Option      "AccelMethod" "none"
EndSection
_XORG_EVDI_CONFIG_
}

# nvidia displaylink xorg.conf (issue: 176)
function xorg_nvidia() {
	cat > "$xorg_config_displaylink" <<_XORG_NVIDIA_CONFIG_
Section "ServerLayout"
    Identifier "layout"
    Screen 0 "nvidia"
    Inactive "intel"
EndSection

Section "Device"
    Identifier "intel"
    Driver "modesetting"
    Option "AccelMethod" "None"
EndSection

Section "Screen"
    Identifier "intel"
    Device "intel"
EndSection

Section "Device"
    Identifier "nvidia"
    Driver "nvidia"
    Option "ConstrainCursor" "off"
EndSection

Section "Screen"
    Identifier "nvidia"
    Device "nvidia"
    Option "AllowEmptyInitialConfiguration" "on"
    Option "IgnoreDisplayDevices" "CRT"
EndSection
_XORG_NVIDIA_CONFIG_
}

# setup xorg.conf depending on graphics card
function modesetting() {
	test ! -d /etc/X11/xorg.conf.d && mkdir -p /etc/X11/xorg.conf.d

	local -r driver=$(lspci -nnk | grep -i vga -A3 | grep 'in use' | cut -d":" -f2 | sed 's/ //g')
	local -r driver_nvidia=$(lspci | grep -i '3d controller' | sed 's/^.*: //' | awk '{print $1}')
	local -r card_subsystem=$(lspci -nnk | grep -i vga -A3 | grep Subsystem | cut -d" " -f5)

	# set xorg for Nvidia cards (issue: 176, 179, 211, 217, 596)
	if [ "$driver_nvidia" == "NVIDIA" ] || [[ $driver == *"nvidia"* ]]; then
		nvidia_pregame
		xorg_nvidia
		#nvidia_hashcat
	# set xorg for AMD cards (issue: 180)
	elif [ "$driver" == "amdgpu" ]; then
		xorg_amd
	# set xorg for Intel cards
	elif [ "$driver" == "i915" ]; then
		# set xorg modesetting for Intel cards (issue: 179, 68, 88, 192)
		local -r supported_subsystems=(
			'530'
			'540'
			'620'
			'GT2'
			'HD'
			'UHD'
			'v2/3rd'
		)

		if [ "${supported_subsystems[*]/$card_subsystem/}" != "${supported_subsystems[*]}" ]; then
			if [ "$(ver2int "$xorg_vcheck")" -gt "$(ver2int "$newgen_xorg")" ]; then
				# reference: issue #200
				xorg_modesetting_newgen
			else
				xorg_modesetting
			fi
		# generic intel
		else
			xorg_intel
		fi
	# default xorg modesetting
	else
		if [ "$(ver2int "$xorg_vcheck")" -gt "$(ver2int "$newgen_xorg")" ]; then
			# reference: issue #200
			xorg_modesetting_newgen
		else
			xorg_modesetting
		fi
	fi

	echo -e "Wrote X11 changes to: $xorg_config_displaylink"
	chown root: "$xorg_config_displaylink"
	chmod 644 "$xorg_config_displaylink"
}

# performs post-installation steps
function post_install() {
	separator
	echo -e "\nPerforming post install steps\n"

	# remove Kconfig file if it does not exist?
	[ "$kconfig_exists" = false ] && rm "$kconfig_file"

	# fix: issue #42 (dlm.service can't start)
	# note: for this to work libstdc++6 package needs to be installed from >= Stretch
	if [[ "$lsb" =~ ^(Debian|Devuan|Kali)$ ]]; then
		# partially addresses meta issue #931
		local -r displaylink_dir='/opt/displaylink'
		[ ! -d "$displaylink_dir" ] && mkdir -p "$displaylink_dir"
		ln -sf /usr/lib/x86_64-linux-gnu/libstdc++.so.6 "$displaylink_dir/libstdc++.so.6"
	fi

	case "$(get_init_system)" in
		'systemd')
			local -r displaylink_driver_service='/lib/systemd/system/displaylink-driver.service'
            if [ ! -f "$displaylink_driver_service" ]; then
                echo -e "DisplayLink driver service not found!\nInstallation failed!\nExiting..."
                exit 1
            fi

			# Fix inability to enable displaylink-driver.service
			sed -i "/RestartSec=5/a[Install]\nWantedBy=multi-user.target" "$displaylink_driver_service"

			echo "Enable displaylink-driver service"
			systemctl enable displaylink-driver.service
			;;

		'sysvinit')
			local -r init_script_path="/etc/init.d/${init_script}"

			echo -e "Copying init script to /etc/init.d\n"
			cp "$dir/$init_script" /etc/init.d/
			chmod +x "$init_script_path"

			echo "Load evdi at startup"
			cat > "$evdi_modprobe" <<_EVDI_MODPROBE_
evdi
_EVDI_MODPROBE_
			echo "Enable and start displaylink service"
			update-rc.d "$init_script" defaults
			"$init_script_path" start
			;;
	esac

	# depending on X11 version start modesetting func
	if [ "$(ver2int "$xorg_vcheck")" -gt "$(ver2int "$min_xorg")" ]; then
		echo "Setup DisplayLink xorg.conf depending on graphics card"
		modesetting
	else
		echo "No need to disable PageFlip for modesetting"
	fi
}

# uninstalls the displaylink driver
function uninstall() {
	separator
	echo -e "\nUninstalling ...\n"

	# displaylink-installer uninstall
	local -r kconfig_file="/lib/modules/$(uname -r)/build/Kconfig"

	local -r distros=(
		'BunsenLabs'
		'Bunsenlabs'
		'Debian'
		'Devuan'
		'Deepin'
		'Kali'
		'Uos'
	)

	if [[ "${distros[*]/$lsb/}" != "${distros[*]}" ]] && [ -f "$kconfig_file" ]; then
		rm "$kconfig_file"
	fi

	if [ "$(get_init_system)" == "sysvinit" ]; then
		update-rc.d "$init_script" remove
		rm -f "/etc/init.d/$init_script"
		rm -f "$evdi_modprobe"
	fi

	# run unintsall script
	bash /opt/displaylink/displaylink-installer.sh uninstall && 2>&1>/dev/null

	# remove modesetting file
	if [ -f "$xorg_config_displaylink" ]; then
		echo "Removing Displaylink Xorg config file"
		rm "$xorg_config_displaylink"
	fi

	# delete udl/udlfb from blacklist (issue #207)
	sed -i '/blacklist udlfb/d' $blacklist
	sed -i '/blacklist udl/d' $blacklist
}

# debug: get system information for issue debug
function debug() {
	separator
	echo -e "\nStarting Debug ...\n"

	local -r default='N'
	local answer="$default"

	local -r evdi_version_file='/sys/devices/evdi/version'
	local evdi_version=''

	local -A subject_urls=(
		['Post Installation Guide']='https://github.com/AdnanHodzic/displaylink-debian/blob/master/docs/post-install-guide.md'
		['Troubleshooting most common issues']='https://github.com/AdnanHodzic/displaylink-debian/blob/master/docs/common-issues.md'
	)

	# array contains subject types in their original order
	local -r subjects=(
		'Post Installation Guide'
		'Troubleshooting most common issues'
	)

	local url=''

	for subject in "${subjects[@]}"; do
		url="${subject_urls[$subject]}"

		read -p "Did you read ${subject}? ${url} [y/N] " answer
		answer="${answer:-$default}"

		case "$answer" in
			'Y'|'y')
				echo ''
				continue
				;;

			'N'|'n')
				echo -e "\nPlease read ${subject}: ${url}\n"
				exit 1
				;;

			*)
				invalid_option
				;;
		esac
	done

	if [ -f "$evdi_version_file" ]; then
		evdi_version="$(cat "$evdi_version_file")"
	else
		evdi_version="$evdi_version_file not found"
	fi
	
    # render debug info
    cat <<_DEBUG_INFO_
--------------- Linux system info ----------------

Distro:  $lsb
Release: $codename
Kernel:  $kernel

---------------- DisplayLink info ----------------

Driver version:             $sys_driver_version
DisplayLink service status: $(displaylink_service_check || echo '[SERVICE NOT FOUND]')
EVDI service version:       $evdi_version

------------------ Graphics card -----------------

Vendor:      $graphics_vendor
Subsystem:   $graphics_subcard
VGA:         $vga_info
VGA (3D):    $vga_info_3d
X11 version: $xorg_vcheck

_DEBUG_INFO_

	# render xorg config file paths
    get_xconfig_list

    # render more debug info
    cat <<_DEBUG_INFO_
-------------- DisplayLink xorg.conf -------------

File: $xorg_config_displaylink
$([ -f "$xorg_config_displaylink" ] && echo -e "Contents:\n$(cat $xorg_config_displaylink)" || echo "[CONFIG FILE NOT FOUND]")

-------------------- Monitors --------------------

$providers
_DEBUG_INFO_
}

# interactively asks for operation
function ask_operation() {
	echo -e "\n--------------------------- displaylink-debian -------------------------------"
	echo -e "\nDisplayLink driver installer for Debian and Ubuntu based Linux distributions:\n"
	echo -e "* Debian, Ubuntu, Elementary OS, Mint, Kali, Deepin and many more!"
	echo -e "* Full list of all supported platforms: http://bit.ly/2zrwz2u"
	echo -e "* When submitting a new issue, include Debug information"
	echo -e "\nOptions:\n"
	read -p "[I]nstall
	[D]ebug
	[R]e-install
	[U]ninstall
	[Q]uit

	Select a key: [i/d/r/u/q]: " answer
}

root_check

if [[ "$#" -lt 1 ]];
then
  ask_operation
else
  case "${1}" in
    "--install")
        answer="i"
        ;;
    "--uninstall")
        answer="u"
        ;;
    "--reinstall")
        answer="r"
        ;;
    "--debug")
        answer="d"
        ;;
    *)
        answer="n"
        ;;
  esac
fi

if [[ $answer == [Ii] ]];
then
	distro_check
	pre_install
	install
	post_install
	clean_up
	separator
	echo -e "\nInstall complete, please reboot to apply the changes"
	echo -e "After reboot, make sure to consult post-install guide! https://github.com/AdnanHodzic/displaylink-debian/blob/master/docs/post-install-guide.md"
	setup_complete
	separator
	echo ""
elif [[ $answer == [Uu] ]];
then
	distro_check
	uninstall
	clean_up
	separator
	echo -e "\nUninstall complete, please reboot to apply the changes"
	setup_complete
	separator
	echo ""
elif [[ $answer == [Rr] ]];
then
	distro_check
	uninstall
	clean_up
	distro_check
	pre_install
	install
	post_install
	clean_up
	separator
	echo -e "\nInstall complete, please reboot to apply the changes"
	echo -e "After reboot, make sure to consult post-install guide! https://github.com/AdnanHodzic/displaylink-debian/blob/master/docs/post-install-guide.md"
	setup_complete
	separator
	echo ""
elif [[ $answer == [Dd] ]];
then
	debug
	separator
	echo -e "\nUse this information when submitting an issue (http://bit.ly/2GLDlpY)"
	separator
	echo ""
elif [[ $answer == [Qq] ]];
then
	separator
	echo ""
	exit 0
else
	echo -e "\nWrong key, aborting ...\n"
	exit 1
fi
