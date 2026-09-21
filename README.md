# NIC_Changer

Tool to quickly change Windows network interface settings

## Overview

Windows-Native GUI interface built for Audio Visual technicians or anyone who needs to quickly switch between DHCP, Link-Local, and Static IP addresses.

This is essentially one large powershell script with no additional dependencies.

![app picture](/assets/app_pic.png)
![subnet scan](/assets/subnet_scan.png)

## Quickstart

All you need to is run `NIC_Changer.ps1`.

If you have issues due to security settings, simply copy the code from `NIC_Changer.ps1` into Notepad, then save the file as `File name: NIC_Changer.ps1` and `Save as type: All files (*.*)`

## Acknowledgments

This project builds upon the work of alecdvor. Their repository <https://github.com/alecdvor/netChanger/> provided the foundation for this project.

## Changes Made

### Version 1

- Hide the console window
- Add check for admin rights
- Add 'try to re-launch as admin' method
- Add subnet mask feature and GUI element
- GUI Improvements
(perception of responsiveness, disable buttons when busy)

- Change function name (to clear an unapproved verb warning)
- Add debugging prints.  These print when the console is shown.
- Changed "Force Link Local" to check for address availiability first
(slightly more RFC 3927 compliant)
- Removed unused VLAN code and references
- Fixed "Internet Connection" bug where the test was not using the selected adapter

### Version 2

- Complete GUI overhaul, with dark mode option
- Subnet scanning, searching, and reporting to return active IP addresses, host names, and MAC addresses per interface.
- DNS Check
- Async GUI updates and test results
- CIDR Selection for subnet mask
- Static IP collision detection and warning
- Input verification
- Enhanced adapter type checking and filtering, including support for vEthernet and virtual switches found in Hyper-V enabled PC's
- Accessibility improvements
