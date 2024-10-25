# NIC_Changer
Tool to quickly change Windows network interface settings

## Acknowledgments
This project builds upon the work of alecdvor. Their repository https://github.com/alecdvor/netChanger/ provided the foundation for this project.

![image](https://github.com/user-attachments/assets/22da352e-f08f-47ba-8de0-ed933dc84b91)

## Changes Made
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


