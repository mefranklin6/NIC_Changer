# NIC_Changer
Tool to quickly change Windows network interface settings

## Acknowledgments
This project builds upon the work of alecdvor. Their repository https://github.com/alecdvor/netChanger/ provided the foundation for this project.

## Changes Made
- Add hide console window
- Add check for admin rights
- Add try to launch as admin method
- Add subnet mask feature
- GUI Improvements
(perception of responsiveness, disable buttons when busy)

- Change function name (unapproved verb warning)
- Add debugging prints
- Changed "Force Link Local" to check for address availiability first
(slightly more RFC 3927 compliant)

- Removed unused VLAN code and references
