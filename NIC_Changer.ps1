# Add-Type to define a method to hide the console window
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class ConsoleHelper {
    [DllImport("kernel32.dll")]
    public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    public const int SW_HIDE = 0;
    public const int SW_SHOW = 5;
    public static void HideConsole() {
        IntPtr hWnd = GetConsoleWindow();
        ShowWindow(hWnd, SW_HIDE);
    }
}
"@

Add-Type -AssemblyName System.Windows.Forms


# Comment out to show console for debugging
[ConsoleHelper]::HideConsole()


# Check if we have privileges to change network settings
$adminGroup = "S-1-5-32-544"
$runningAsAdmin = [bool](([System.Security.Principal.WindowsIdentity]::GetCurrent()).groups -match $adminGroup)
if (-not $runningAsAdmin) {
    # Relaunch the script with elevated permissions
    $newProcess = Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs -PassThru
    if ($newProcess) {
        exit
    }
    else {
        Write-Host "Failed to relaunch the script with administrative privileges."
        exit
    }
}



# Create form
$form = New-Object System.Windows.Forms.Form
$form.Text = "netChanger"
$form.Size = New-Object System.Drawing.Size(700, 410)  
$form.StartPosition = "CenterScreen"


$listBoxInterfaces = New-Object System.Windows.Forms.ListBox
$listBoxInterfaces.Location = New-Object System.Drawing.Point(10, 50)
$listBoxInterfaces.Size = New-Object System.Drawing.Size(240, 200)
$listBoxInterfaces.Add_SelectedIndexChanged({
        Get-SelectedInterfaceInfo
    })

$textBoxInfo = New-Object System.Windows.Forms.TextBox
$textBoxInfo.Location = New-Object System.Drawing.Point(260, 50)
$textBoxInfo.Size = New-Object System.Drawing.Size(420, 200)
$textBoxInfo.Multiline = $true
$textBoxInfo.ReadOnly = $true
if (-not $runningAsAdmin) {
    $textBoxInfo.Text = "Read-only mode. Admin privileges required to change network settings."
}

$btnCaptureIP = New-Object System.Windows.Forms.Button
$btnCaptureIP.Text = "Capture IP"
$btnCaptureIP.Location = New-Object System.Drawing.Point(10, 260)
$btnCaptureIP.Size = New-Object System.Drawing.Size(100, 30)
$btnCaptureIP.Add_Click({
        Capture-Current-IPv4
    })

# Add editable text field linked to the captured IP variable
$textBoxCapturedIP = New-Object System.Windows.Forms.TextBox
$textBoxCapturedIP.Location = New-Object System.Drawing.Point(120, 260)
$textBoxCapturedIP.Size = New-Object System.Drawing.Size(120, 30)
$textBoxCapturedIP.Text = ''
$textBoxCapturedIP.Add_TextChanged({
        $selectedInterface = $listBoxInterfaces.SelectedItem
        $enteredIP = $textBoxCapturedIP.Text.Trim()

        if ($selectedInterface) {
            if ([string]::IsNullOrWhiteSpace($enteredIP)) {
                $CapturedIPs.Remove($selectedInterface)
            }
            else {
                $CapturedIPs[$selectedInterface] = $enteredIP
            }
        }

        Update-CapturedIPButton
    })

$btnCaptureIPtoSet = New-Object System.Windows.Forms.Button
$btnCaptureIPtoSet.Text = "Capture or Input IP to Set"
$btnCaptureIPtoSet.Location = New-Object System.Drawing.Point(250, 260)
$btnCaptureIPtoSet.Size = New-Object System.Drawing.Size(430, 30) 
$btnCaptureIPtoSet.Enabled = $false
$btnCaptureIPtoSet.Add_Click({
        Set-Captured-IP
    })

# Add editable text field linked to the captured Subnet Mask variable
$textBoxCapturedSubnet = New-Object System.Windows.Forms.TextBox
$textBoxCapturedSubnet.Location = New-Object System.Drawing.Point(120, 300)
$textBoxCapturedSubnet.Size = New-Object System.Drawing.Size(120, 30)
$textBoxCapturedSubnet.Text = '255.255.255.0'

$btnSetDhcpLinkLocal = New-Object System.Windows.Forms.Button
$btnSetDhcpLinkLocal.Text = "Set IP to Dynamic"
$btnSetDhcpLinkLocal.Location = New-Object System.Drawing.Point(250, 300) 
$btnSetDhcpLinkLocal.Size = New-Object System.Drawing.Size(430, 30)
$btnSetDhcpLinkLocal.Enabled = $runningAsAdmin  
$btnSetDhcpLinkLocal.Add_Click({
        Set-DHCP-LinkLocal-IP
    })

$btnSetLinkLocal = New-Object System.Windows.Forms.Button
$btnSetLinkLocal.Text = "Set to Force Link Local"
$btnSetLinkLocal.Location = New-Object System.Drawing.Point(250, 340) 
$btnSetLinkLocal.Size = New-Object System.Drawing.Size(430, 30)
$btnSetLinkLocal.Enabled = $runningAsAdmin 
$btnSetLinkLocal.Add_Click({
        Set-RandomLinkLocal-IP
    })


$ButtonGroup = ($btnSetLinkLocal, $btnSetDhcpLinkLocal, $btnCaptureIPtoSet, $btnCaptureIP)

function ButtonGroupEnable {
    param(
        [bool]$enable
    )
    $interfaceSelected = $null -ne $listBoxInterfaces.SelectedItem
    $buttonsEnabled = $enable -and $interfaceSelected -and $runningAsAdmin

    $btnSetLinkLocal.Enabled = $buttonsEnabled
    $btnSetDhcpLinkLocal.Enabled = $buttonsEnabled
    $btnCaptureIP.Enabled = $buttonsEnabled
    Update-CapturedIPButton -EnableGroup:$enable
}

function Update-CapturedIPButton {
    param(
        [bool]$EnableGroup = $true
    )

    $enteredIP = $textBoxCapturedIP.Text.Trim()
    $hasIP = -not [string]::IsNullOrWhiteSpace($enteredIP)
    $interfaceSelected = $null -ne $listBoxInterfaces.SelectedItem

    if ($hasIP) {
        $btnCaptureIPtoSet.Text = "Set IP to $enteredIP"
    }
    else {
        $btnCaptureIPtoSet.Text = "Capture or Input IP to Set"
    }

    $btnCaptureIPtoSet.Enabled = $EnableGroup -and $interfaceSelected -and $runningAsAdmin -and $hasIP
}


# Function to set the DHCP and Link Local IP for the selected interface
function Set-DHCP-LinkLocal-IP {
    $selectedInterface = $listBoxInterfaces.SelectedItem

    if ($selectedInterface -ne $null) {
        Write-Host "Setting DHCP IP for $($selectedInterface)"

        # Set DHCP IP for the selected interface using Netsh
        try {
            netsh interface ipv4 set address name=$selectedInterface source=dhcp
            #[Windows.Forms.MessageBox]::Show("DHCP IP set successfully for: $($selectedInterface)", "DHCP IP Set")
        }
        catch {
            Write-Host "Error setting DHCP IP: $_"
            [Windows.Forms.MessageBox]::Show("Failed to set DHCP IP. Check for errors.", "DCHP IP Set Error")
        }

        # Refresh the displayed information after setting the DHCP/Link Local IP
        Get-SelectedInterfaceInfo
    }
}

# Function to refresh network interfaces
function Get-NetworkInterface {
    $interfaces = Get-NetAdapter

    $listBoxInterfaces.Items.Clear()
    foreach ($interface in $interfaces) {
        $interfaceAlias = $interface.InterfaceAlias
        if (-not [string]::IsNullOrEmpty($interfaceAlias)) {
            $listBoxInterfaces.Items.Add($interfaceAlias)
        }
    }
}


function Get-ConnectivityStatus {
    param (
        [string]$selectedInterfaceIP
    )

    # Test an IP address first so the internet check does not depend on DNS.
    & ping.exe -S $selectedInterfaceIP -n 2 -w 1000 1.1.1.1 *> $null
    $ipReachable = $LASTEXITCODE -eq 0

    # A successful hostname ping proves both connectivity and DNS resolution.
    & ping.exe -S $selectedInterfaceIP -n 2 -w 1000 www.cloudflare.com *> $null
    $dnsReachable = $LASTEXITCODE -eq 0

    return [PSCustomObject]@{
        Internet = $ipReachable -or $dnsReachable
        DNS      = $dnsReachable
    }
}


# Function to get selected interface info
function Get-SelectedInterfaceInfo {
    $selectedInterface = $listBoxInterfaces.SelectedItem

    if ($selectedInterface) {
        Write-Host "Selected interface: $selectedInterface"
        ButtonGroupEnable($false)
        $textBoxInfo.Text = "Please Wait..."

        try {
            Write-Host "Retrieving interface information"
            $interfaceInfo = Get-NetAdapter | Where-Object { $_.InterfaceAlias -eq $selectedInterface }

            if (-not $interfaceInfo) {
                throw "Interface not found"
            }

            $infoText = "Interface: $($interfaceInfo.InterfaceAlias)`r`n"
            $infoText += "Status: $($interfaceInfo.Status)`r`n"

            Write-Host "Retrieving IPv4 addresses"
            $ipv4Addresses = (Get-NetIPAddress -InterfaceAlias $selectedInterface -AddressFamily IPv4).IPAddress
            $ipv4SubnetMask = (Get-NetIPAddress -InterfaceAlias $selectedInterface -AddressFamily IPv4).PrefixLength
            Write-Host "Retrieving IPv6 addresses"
            $ipv6Addresses = (Get-NetIPAddress -InterfaceAlias $selectedInterface -AddressFamily IPv6).IPAddress

            $infoText += "IPv4 Addresses: $($ipv4Addresses -join ', ')`r`n"
            $infoText += "IPv4 Subnet Mask: $ipv4SubnetMask`r`n"
            $infoText += "IPv6 Addresses: $($ipv6Addresses -join ', ')`r`n"

            try {
                $selectedInterfaceIP = [System.Net.IPAddress]::Parse($ipv4Addresses)
                Write-Host "Selected Interface IP: $selectedInterfaceIP"
                
                $connectivityStatus = Get-ConnectivityStatus -selectedInterfaceIP $selectedInterfaceIP

                if ($connectivityStatus.Internet) {
                    $infoText += "Internet Connection: Success`r`n"
                }
                else {
                    $infoText += "Internet Connection: Failed`r`n"
                }

                if ($connectivityStatus.DNS) {
                    $infoText += "DNS Resolution: Success`r`n"
                }
                else {
                    $infoText += "DNS Resolution: Failed`r`n"
                }
            }
            catch {
                # Will fail the IPAddress parse if interface is disabled
                Write-Host "Error: $_"
                $infoText += "Error retrieving internet connection status`r`n"
            }

            ButtonGroupEnable($true)

            Write-Host "Setting Capture to Set button text"
            if ($CapturedIPs.ContainsKey($selectedInterface)) {
                $btnCaptureIPtoSet.Text = "Set IP to $($CapturedIPs[$selectedInterface])"
                $textBoxCapturedIP.Text = $CapturedIPs[$selectedInterface]
            }
            else {
                $btnCaptureIPtoSet.Text = "Capture or Input IP to Set"
                $textBoxCapturedIP.Text = ""
            }

            $textBoxInfo.Text = $infoText
        }
        catch {
            Write-Host "Error: $_"
            $textBoxInfo.Text = "Error retrieving interface information"
            ButtonGroupEnable($true)
        }
    }
    else {
        Write-Host "No interface selected"
    }
}

# Function to capture the current IPv4 of the selected interface
function Capture-Current-IPv4 {
    $selectedInterface = $listBoxInterfaces.SelectedItem

    if ($selectedInterface) {
        $currentIPv4 = (Get-NetIPAddress -InterfaceAlias $selectedInterface -AddressFamily IPv4).IPAddress
        Write-Host "Captured current IPv4 for $($selectedInterface): $($currentIPv4)"

        # Store the captured IPv4 in a variable unique to the adapter
        $CapturedIPs[$selectedInterface] = $currentIPv4

        # Update the label of the "Capture to Set" button
        $btnCaptureIPtoSet.Text = "Set IP to $($currentIPv4)"
        $textBoxCapturedIP.Text = $currentIPv4
    }
}

function ValidateSubnetMask {
    param(
        [string]$subnet
    )
    
    try {
        $subnet_mask = [System.Net.IPAddress]::Parse($subnet)
    }
    catch {
        $subnet_mask = [System.Net.IPAddress]::Parse("255.255.255.0")
    }
    
    return $subnet_mask
}

# Function to set the captured IP using Netsh
function Set-Captured-IP {
    $selectedInterface = $listBoxInterfaces.SelectedItem

    if ($selectedInterface -ne $null -and $CapturedIPs.ContainsKey($selectedInterface)) {
        $capturedIP = $CapturedIPs[$selectedInterface]
        Write-Host "Setting IP for $($selectedInterface): $($capturedIP)"

        $desired_subnet = ValidateSubnetMask($textBoxCapturedSubnet.Text)
        Write-Host "Desired subnet: $desired_subnet"


        # Set the captured IP for the selected interface using Netsh
        try {
            netsh interface ipv4 set address name=$selectedInterface static $capturedIP $desired_subnet
            #[Windows.Forms.MessageBox]::Show("IP set successfully to: $($capturedIP)", "IP Set")
        }
        catch {
            Write-Host "Error setting IP: $_"
            [Windows.Forms.MessageBox]::Show("Failed to set IP. Check the provided IP address.", "IP Set Error")
        }

        # Refresh the displayed information after setting the IP
        Get-SelectedInterfaceInfo
    }
}


# Function to set a random Link Local IPv4 address for the selected interface
function Set-RandomLinkLocal-IP {
    $selectedInterface = $listBoxInterfaces.SelectedItem

    if ($selectedInterface -ne $null) {
        Write-Host "Setting Random Link Local IP for $($selectedInterface)"

        $ipInUse = $true
        while ($ipInUse) {
            # Generate a random Link Local IP address
            $randomIp = "169.254.{0}.{1}" -f (Get-Random -Minimum 1 -Maximum 255), (Get-Random -Minimum 1 -Maximum 255)

            # Ping the address to check if it is in use
            $pingResult = Test-Connection -ComputerName $randomIp -Count 1 -Quiet

            if (-not $pingResult) {
                $ipInUse = $false
            }
            else {
                Write-Host "IP address $randomIp is in use. Generating a new one..."
            }
        }

        # Set the Link Local IP for the selected interface using Netsh
        try {
            netsh interface ipv4 set address name=$selectedInterface source=static address=$randomIp mask=255.255.0.0
            #[Windows.Forms.MessageBox]::Show("Link Local IP set successfully for: $($selectedInterface)`nIP Address: $($randomIp)", "Link Local IP Set")
        }
        catch {
            Write-Host "Error setting Link Local IP: $_"
            [Windows.Forms.MessageBox]::Show("Failed to set Link Local IP. Check for errors.", "Link Local IP Set Error")
        }

        # Refresh the displayed information after setting the Link Local IP
        Get-SelectedInterfaceInfo
    }
}


# Hash table to store captured IPs
$CapturedIPs = @{}

# Add controls to form
$form.Controls.Add($listBoxInterfaces)
$form.Controls.Add($textBoxInfo)
$form.Controls.Add($btnCaptureIP)
$form.Controls.Add($textBoxCapturedIP)
$form.Controls.Add($btnCaptureIPtoSet)
$form.Controls.Add($textBoxCapturedSubnet)
$form.Controls.Add($btnSetLinkLocal)
$form.Controls.Add($btnSetDhcpLinkLocal)

# Keep interface actions disabled until the user selects an interface.
ButtonGroupEnable($false)

# Set form event handler
$form.Add_Shown({
        Get-NetworkInterface
    })

# Display the form
[Windows.Forms.Application]::Run($form)
