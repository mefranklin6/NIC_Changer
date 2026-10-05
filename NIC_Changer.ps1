# Add the native Windows helper once per PowerShell process.
if (-not ('NICChangerNativeV2' -as [type])) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public class NICChangerNativeV2 {
    [DllImport("kernel32.dll")]
    public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hWnd, int attribute, ref int value, int valueSize);
    public const int SW_HIDE = 0;
    public const int SW_SHOW = 5;
    public static void HideConsole() {
        IntPtr hWnd = GetConsoleWindow();
        ShowWindow(hWnd, SW_HIDE);
    }
    public static void SetDarkTitleBar(IntPtr hWnd, bool useDarkMode) {
        if (Environment.OSVersion.Version.Major < 10) return;

        int enabled = useDarkMode ? 1 : 0;
        int result = DwmSetWindowAttribute(hWnd, 20, ref enabled, sizeof(int));
        if (result != 0) {
            DwmSetWindowAttribute(hWnd, 19, ref enabled, sizeof(int));
        }
    }
}
"@
}

# A small in-process DHCPv4 implementation keeps the utility dependency-free.
# It is deliberately limited to the directly connected IPv4 subnet selected in
# the UI; relay-agent requests are ignored.
if (-not ('NICChangerDhcpServer' -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;

public sealed class NICChangerDhcpProbeResult
{
    public bool ServerFound { get; set; }
    public string ServerIdentifier { get; set; }
    public string SourceAddress { get; set; }
    public string Error { get; set; }
}

public sealed class NICChangerDhcpLeaseView
{
    public string IPAddress { get; set; }
    public string MacAddress { get; set; }
    public string HostName { get; set; }
    public string Status { get; set; }
    public DateTime LeasedAt { get; set; }
    public DateTime ExpiresAt { get; set; }
}

internal sealed class NICChangerDhcpLeaseEntry
{
    public string ClientKey;
    public uint Address;
    public string MacAddress;
    public string HostName;
    public string Status;
    public DateTime LeasedAt;
    public DateTime ExpiresAt;
}

internal sealed class NICChangerDhcpOffer
{
    public uint Address;
    public DateTime ExpiresAt;
}

internal static class NICChangerDhcpProtocol
{
    internal static uint ReadUInt32(byte[] bytes, int offset)
    {
        return ((uint)bytes[offset] << 24) | ((uint)bytes[offset + 1] << 16) |
               ((uint)bytes[offset + 2] << 8) | bytes[offset + 3];
    }

    internal static void WriteUInt32(byte[] bytes, int offset, uint value)
    {
        bytes[offset] = (byte)(value >> 24);
        bytes[offset + 1] = (byte)(value >> 16);
        bytes[offset + 2] = (byte)(value >> 8);
        bytes[offset + 3] = (byte)value;
    }

    internal static uint AddressToUInt32(IPAddress address)
    {
        byte[] bytes = address.GetAddressBytes();
        return ((uint)bytes[0] << 24) | ((uint)bytes[1] << 16) |
               ((uint)bytes[2] << 8) | bytes[3];
    }

    internal static IPAddress UInt32ToAddress(uint value)
    {
        return new IPAddress(new byte[] {
            (byte)(value >> 24), (byte)(value >> 16),
            (byte)(value >> 8), (byte)value
        });
    }

    internal static byte[] FindOption(byte[] packet, int length, byte code)
    {
        if (length < 240 || packet[236] != 99 || packet[237] != 130 ||
            packet[238] != 83 || packet[239] != 99) return null;

        int index = 240;
        while (index < length)
        {
            byte optionCode = packet[index++];
            if (optionCode == 255) break;
            if (optionCode == 0) continue;
            if (index >= length) break;
            int optionLength = packet[index++];
            if (index + optionLength > length) break;
            if (optionCode == code)
            {
                byte[] value = new byte[optionLength];
                Buffer.BlockCopy(packet, index, value, 0, optionLength);
                return value;
            }
            index += optionLength;
        }
        return null;
    }

    internal static string FormatMac(byte[] packet, int length)
    {
        int macLength = length > 2 ? Math.Min((int)packet[2], 16) : 0;
        if (length < 28 + macLength || macLength == 0) return "Unknown";
        StringBuilder builder = new StringBuilder();
        for (int index = 0; index < macLength; index++)
        {
            if (index > 0) builder.Append('-');
            builder.Append(packet[28 + index].ToString("X2"));
        }
        return builder.ToString();
    }

    internal static string GetClientKey(byte[] packet, int length)
    {
        byte[] clientIdentifier = FindOption(packet, length, 61);
        if (clientIdentifier != null && clientIdentifier.Length > 0)
            return "ID:" + BitConverter.ToString(clientIdentifier);
        return "MAC:" + FormatMac(packet, length);
    }

    internal static string GetHostName(byte[] packet, int length)
    {
        byte[] hostName = FindOption(packet, length, 12);
        if (hostName == null || hostName.Length == 0) return "";
        string value = Encoding.ASCII.GetString(hostName).Trim();
        StringBuilder safe = new StringBuilder();
        foreach (char character in value)
        {
            if (character >= 32 && character <= 126) safe.Append(character);
        }
        return safe.ToString();
    }

    internal static void AddOption(List<byte> packet, byte code, byte[] value)
    {
        if (value == null || value.Length == 0 || value.Length > 255) return;
        packet.Add(code);
        packet.Add((byte)value.Length);
        packet.AddRange(value);
    }

    internal static byte[] UInt32Bytes(uint value)
    {
        return new byte[] {
            (byte)(value >> 24), (byte)(value >> 16),
            (byte)(value >> 8), (byte)value
        };
    }

    internal static byte[] AddressListBytes(IPAddress[] addresses)
    {
        List<byte> result = new List<byte>();
        if (addresses != null)
        {
            foreach (IPAddress address in addresses) result.AddRange(address.GetAddressBytes());
        }
        return result.ToArray();
    }
}

public static class NICChangerDhcpProbe
{
    public static NICChangerDhcpProbeResult Probe(int interfaceIndex, string broadcastAddress, int timeoutMilliseconds)
    {
        NICChangerDhcpProbeResult result = new NICChangerDhcpProbeResult();
        Socket socket = null;
        try
        {
            socket = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp);
            socket.ExclusiveAddressUse = false;
            socket.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
            socket.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.Broadcast, true);
            socket.SetSocketOption(SocketOptionLevel.IP, SocketOptionName.PacketInformation, true);
            socket.SetSocketOption(SocketOptionLevel.IP, (SocketOptionName)31,
                IPAddress.HostToNetworkOrder(interfaceIndex));
            socket.Bind(new IPEndPoint(IPAddress.Any, 68));
            socket.ReceiveTimeout = 350;
            IPAddress probeDestination = IPAddress.Parse(broadcastAddress);

            byte[] request = new byte[253];
            request[0] = 1;
            request[1] = 1;
            request[2] = 6;
            byte[] transactionBytes = Guid.NewGuid().ToByteArray();
            Buffer.BlockCopy(transactionBytes, 0, request, 4, 4);
            request[10] = 128;
            request[28] = 2;
            Buffer.BlockCopy(transactionBytes, 4, request, 29, 5);
            request[236] = 99; request[237] = 130; request[238] = 83; request[239] = 99;
            request[240] = 53; request[241] = 1; request[242] = 1;
            request[243] = 61; request[244] = 7; request[245] = 1;
            Buffer.BlockCopy(request, 28, request, 246, 6);
            request[252] = 255;

            DateTime deadline = DateTime.UtcNow.AddMilliseconds(timeoutMilliseconds);
            DateTime nextSend = DateTime.MinValue;
            while (DateTime.UtcNow < deadline)
            {
                if (DateTime.UtcNow >= nextSend)
                {
                    socket.SendTo(request, new IPEndPoint(probeDestination, 67));
                    nextSend = DateTime.UtcNow.AddMilliseconds(900);
                }

                try
                {
                    byte[] response = new byte[1500];
                    EndPoint remote = new IPEndPoint(IPAddress.Any, 0);
                    SocketFlags flags = SocketFlags.None;
                    IPPacketInformation packetInformation;
                    int received = socket.ReceiveMessageFrom(response, 0, response.Length, ref flags,
                        ref remote, out packetInformation);
                    if (packetInformation.Interface != 0 && packetInformation.Interface != interfaceIndex) continue;
                    if (received < 244 || response[0] != 2) continue;
                    bool transactionMatches = true;
                    for (int index = 0; index < 4; index++)
                        if (response[4 + index] != request[4 + index]) transactionMatches = false;
                    if (!transactionMatches) continue;

                    byte[] messageType = NICChangerDhcpProtocol.FindOption(response, received, 53);
                    if (messageType == null || messageType.Length != 1 ||
                        (messageType[0] != 2 && messageType[0] != 5)) continue;

                    byte[] serverIdentifier = NICChangerDhcpProtocol.FindOption(response, received, 54);
                    result.ServerFound = true;
                    result.SourceAddress = ((IPEndPoint)remote).Address.ToString();
                    result.ServerIdentifier = serverIdentifier != null && serverIdentifier.Length == 4
                        ? new IPAddress(serverIdentifier).ToString()
                        : result.SourceAddress;
                    return result;
                }
                catch (SocketException exception)
                {
                    if (exception.SocketErrorCode != SocketError.TimedOut &&
                        exception.SocketErrorCode != SocketError.WouldBlock) throw;
                }
            }
        }
        catch (Exception exception)
        {
            result.Error = exception.Message;
        }
        finally
        {
            if (socket != null) socket.Close();
        }
        return result;
    }
}

public sealed class NICChangerDhcpServer : IDisposable
{
    private readonly object _sync = new object();
    private readonly IPAddress _serverAddress;
    private readonly uint _serverAddressValue;
    private readonly IPAddress _broadcastAddress;
    private readonly int _interfaceIndex;
    private readonly uint _poolStart;
    private readonly uint _poolEnd;
    private readonly IPAddress _subnetMask;
    private readonly IPAddress _router;
    private readonly IPAddress[] _dnsServers;
    private readonly IPAddress[] _ntpServers;
    private readonly string _domainName;
    private readonly uint _leaseSeconds;
    private readonly List<NICChangerDhcpLeaseEntry> _leases = new List<NICChangerDhcpLeaseEntry>();
    private readonly Dictionary<string, NICChangerDhcpOffer> _offers = new Dictionary<string, NICChangerDhcpOffer>();
    private readonly Dictionary<uint, DateTime> _declined = new Dictionary<uint, DateTime>();
    private Socket _socket;
    private Thread _thread;
    private volatile bool _running;
    private string _lastError = "";

    public NICChangerDhcpServer(string serverAddress, int interfaceIndex, string poolStart, int poolSize,
        string subnetMask, string router, string[] dnsServers, string[] ntpServers,
        string domainName, int leaseMinutes)
    {
        if (poolSize < 1) throw new ArgumentOutOfRangeException("poolSize");
        _serverAddress = IPAddress.Parse(serverAddress);
        _serverAddressValue = NICChangerDhcpProtocol.AddressToUInt32(_serverAddress);
        _interfaceIndex = interfaceIndex;
        _poolStart = NICChangerDhcpProtocol.AddressToUInt32(IPAddress.Parse(poolStart));
        _poolEnd = checked(_poolStart + (uint)poolSize - 1);
        _subnetMask = IPAddress.Parse(subnetMask);
        uint maskValue = NICChangerDhcpProtocol.AddressToUInt32(_subnetMask);
        _broadcastAddress = NICChangerDhcpProtocol.UInt32ToAddress(
            (_serverAddressValue & maskValue) | ~maskValue);
        _router = String.IsNullOrWhiteSpace(router) ? null : IPAddress.Parse(router);
        _dnsServers = ParseAddresses(dnsServers);
        _ntpServers = ParseAddresses(ntpServers);
        _domainName = domainName == null ? "" : domainName.Trim();
        _leaseSeconds = checked((uint)leaseMinutes * 60U);
    }

    public bool IsRunning { get { return _running; } }
    public string LastError { get { lock (_sync) { return _lastError; } } }

    private static IPAddress[] ParseAddresses(string[] values)
    {
        List<IPAddress> result = new List<IPAddress>();
        if (values != null)
        {
            foreach (string value in values)
                if (!String.IsNullOrWhiteSpace(value)) result.Add(IPAddress.Parse(value));
        }
        return result.ToArray();
    }

    public void Start()
    {
        lock (_sync)
        {
            if (_running) return;
            _lastError = "";
            _socket = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp);
            try
            {
                _socket.ExclusiveAddressUse = false;
                _socket.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
                _socket.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.Broadcast, true);
                _socket.SetSocketOption(SocketOptionLevel.IP, SocketOptionName.PacketInformation, true);
                _socket.SetSocketOption(SocketOptionLevel.IP, (SocketOptionName)31,
                    IPAddress.HostToNetworkOrder(_interfaceIndex));
                _socket.ReceiveTimeout = 500;
                _socket.Bind(new IPEndPoint(IPAddress.Any, 67));
                _running = true;
                _thread = new Thread(ListenLoop);
                _thread.IsBackground = true;
                _thread.Name = "NIC Changer DHCP server";
                _thread.Start();
            }
            catch
            {
                _socket.Close();
                _socket = null;
                throw;
            }
        }
    }

    public void Stop()
    {
        Thread thread;
        lock (_sync)
        {
            _running = false;
            if (_socket != null)
            {
                try { _socket.Close(); } catch { }
                _socket = null;
            }
            thread = _thread;
            _thread = null;
        }
        if (thread != null && thread != Thread.CurrentThread) thread.Join(1500);
    }

    public NICChangerDhcpLeaseView[] GetLeases()
    {
        lock (_sync)
        {
            Cleanup(DateTime.UtcNow);
            List<NICChangerDhcpLeaseView> result = new List<NICChangerDhcpLeaseView>();
            foreach (NICChangerDhcpLeaseEntry lease in _leases)
            {
                result.Add(new NICChangerDhcpLeaseView {
                    IPAddress = NICChangerDhcpProtocol.UInt32ToAddress(lease.Address).ToString(),
                    MacAddress = lease.MacAddress,
                    HostName = lease.HostName,
                    Status = lease.Status,
                    LeasedAt = lease.LeasedAt.ToLocalTime(),
                    ExpiresAt = lease.ExpiresAt.ToLocalTime()
                });
            }
            return result.ToArray();
        }
    }

    private void ListenLoop()
    {
        try
        {
            while (_running)
            {
                try
                {
                    byte[] packet = new byte[1500];
                    EndPoint remote = new IPEndPoint(IPAddress.Any, 0);
                    SocketFlags flags = SocketFlags.None;
                    IPPacketInformation packetInformation;
                    int received = _socket.ReceiveMessageFrom(packet, 0, packet.Length, ref flags,
                        ref remote, out packetInformation);
                    if (packetInformation.Interface != _interfaceIndex) continue;
                    HandlePacket(packet, received);
                }
                catch (SocketException exception)
                {
                    if (!_running) break;
                    if (exception.SocketErrorCode != SocketError.TimedOut &&
                        exception.SocketErrorCode != SocketError.WouldBlock) throw;
                }
                catch (ObjectDisposedException) { if (!_running) break; }
            }
        }
        catch (Exception exception)
        {
            lock (_sync) { _lastError = exception.Message; }
            _running = false;
        }
    }

    private void HandlePacket(byte[] packet, int length)
    {
        if (length < 244 || packet[0] != 1 || packet[1] != 1 || packet[2] == 0) return;
        if (NICChangerDhcpProtocol.ReadUInt32(packet, 24) != 0) return;
        byte[] messageTypeOption = NICChangerDhcpProtocol.FindOption(packet, length, 53);
        if (messageTypeOption == null || messageTypeOption.Length != 1) return;

        byte messageType = messageTypeOption[0];
        string clientKey = NICChangerDhcpProtocol.GetClientKey(packet, length);
        string macAddress = NICChangerDhcpProtocol.FormatMac(packet, length);
        string hostName = NICChangerDhcpProtocol.GetHostName(packet, length);

        if (messageType == 1)
        {
            uint address;
            lock (_sync)
            {
                address = SelectAddress(clientKey, DateTime.UtcNow);
                if (address == 0) return;
                _offers[clientKey] = new NICChangerDhcpOffer {
                    Address = address, ExpiresAt = DateTime.UtcNow.AddSeconds(60)
                };
            }
            SendReply(packet, length, 2, address);
        }
        else if (messageType == 3)
        {
            byte[] requestedServer = NICChangerDhcpProtocol.FindOption(packet, length, 54);
            if (requestedServer != null && requestedServer.Length == 4 &&
                NICChangerDhcpProtocol.ReadUInt32(requestedServer, 0) != _serverAddressValue)
            {
                lock (_sync) { _offers.Remove(clientKey); }
                return;
            }

            byte[] requestedAddressOption = NICChangerDhcpProtocol.FindOption(packet, length, 50);
            uint requestedAddress = requestedAddressOption != null && requestedAddressOption.Length == 4
                ? NICChangerDhcpProtocol.ReadUInt32(requestedAddressOption, 0)
                : NICChangerDhcpProtocol.ReadUInt32(packet, 12);

            bool accepted;
            lock (_sync)
            {
                Cleanup(DateTime.UtcNow);
                accepted = requestedAddress >= _poolStart && requestedAddress <= _poolEnd &&
                    !AddressBelongsToOtherClient(requestedAddress, clientKey);
                if (accepted) CommitLease(clientKey, requestedAddress, macAddress, hostName);
                _offers.Remove(clientKey);
            }
            SendReply(packet, length, accepted ? (byte)5 : (byte)6, accepted ? requestedAddress : 0);
        }
        else if (messageType == 4)
        {
            byte[] declinedAddress = NICChangerDhcpProtocol.FindOption(packet, length, 50);
            if (declinedAddress != null && declinedAddress.Length == 4)
            {
                uint address = NICChangerDhcpProtocol.ReadUInt32(declinedAddress, 0);
                lock (_sync) { _declined[address] = DateTime.UtcNow.AddMinutes(10); }
            }
        }
        else if (messageType == 7)
        {
            lock (_sync)
            {
                foreach (NICChangerDhcpLeaseEntry lease in _leases)
                {
                    if (lease.ClientKey == clientKey && lease.Status == "Active")
                    {
                        lease.Status = "Released";
                        lease.ExpiresAt = DateTime.UtcNow;
                    }
                }
            }
        }
        else if (messageType == 8)
        {
            SendReply(packet, length, 5, 0);
        }
    }

    private uint SelectAddress(string clientKey, DateTime now)
    {
        Cleanup(now);
        foreach (NICChangerDhcpLeaseEntry lease in _leases)
            if (lease.ClientKey == clientKey && lease.Status == "Active") return lease.Address;

        NICChangerDhcpOffer existingOffer;
        if (_offers.TryGetValue(clientKey, out existingOffer) && existingOffer.ExpiresAt > now)
            return existingOffer.Address;

        for (uint address = _poolStart; address <= _poolEnd; address++)
        {
            DateTime declinedUntil;
            if (_declined.TryGetValue(address, out declinedUntil) && declinedUntil > now) continue;
            bool used = false;
            foreach (NICChangerDhcpLeaseEntry lease in _leases)
                if (lease.Address == address && lease.Status == "Active") { used = true; break; }
            if (!used)
            {
                foreach (NICChangerDhcpOffer offer in _offers.Values)
                    if (offer.Address == address && offer.ExpiresAt > now) { used = true; break; }
            }
            if (!used) return address;
            if (address == UInt32.MaxValue) break;
        }
        return 0;
    }

    private bool AddressBelongsToOtherClient(uint address, string clientKey)
    {
        foreach (NICChangerDhcpLeaseEntry lease in _leases)
            if (lease.Address == address && lease.Status == "Active" && lease.ClientKey != clientKey) return true;
        return false;
    }

    private void CommitLease(string clientKey, uint address, string macAddress, string hostName)
    {
        DateTime now = DateTime.UtcNow;
        foreach (NICChangerDhcpLeaseEntry other in _leases)
        {
            if (other.Address == address && other.ClientKey != clientKey && other.Status == "Active")
            {
                other.Status = "Expired";
                other.ExpiresAt = now;
            }
        }

        NICChangerDhcpLeaseEntry entry = null;
        foreach (NICChangerDhcpLeaseEntry lease in _leases)
            if (lease.ClientKey == clientKey) { entry = lease; break; }
        if (entry == null)
        {
            entry = new NICChangerDhcpLeaseEntry();
            entry.ClientKey = clientKey;
            _leases.Add(entry);
        }
        entry.Address = address;
        entry.MacAddress = macAddress;
        if (!String.IsNullOrWhiteSpace(hostName) || String.IsNullOrWhiteSpace(entry.HostName))
            entry.HostName = hostName;
        entry.Status = "Active";
        entry.LeasedAt = now;
        entry.ExpiresAt = now.AddSeconds(_leaseSeconds);
    }

    private void Cleanup(DateTime now)
    {
        foreach (NICChangerDhcpLeaseEntry lease in _leases)
            if (lease.Status == "Active" && lease.ExpiresAt <= now) lease.Status = "Expired";

        List<string> expiredOffers = new List<string>();
        foreach (KeyValuePair<string, NICChangerDhcpOffer> offer in _offers)
            if (offer.Value.ExpiresAt <= now) expiredOffers.Add(offer.Key);
        foreach (string key in expiredOffers) _offers.Remove(key);

        List<uint> expiredDeclines = new List<uint>();
        foreach (KeyValuePair<uint, DateTime> decline in _declined)
            if (decline.Value <= now) expiredDeclines.Add(decline.Key);
        foreach (uint address in expiredDeclines) _declined.Remove(address);
    }

    private void SendReply(byte[] request, int requestLength, byte messageType, uint offeredAddress)
    {
        byte[] header = new byte[240];
        header[0] = 2;
        header[1] = request[1];
        header[2] = request[2];
        header[3] = request[3];
        Buffer.BlockCopy(request, 4, header, 4, 4);
        Buffer.BlockCopy(request, 10, header, 10, 2);
        if (messageType == 5 && offeredAddress == 0)
            Buffer.BlockCopy(request, 12, header, 12, 4);
        NICChangerDhcpProtocol.WriteUInt32(header, 16, offeredAddress);
        NICChangerDhcpProtocol.WriteUInt32(header, 20, _serverAddressValue);
        Buffer.BlockCopy(request, 28, header, 28, Math.Min(16, requestLength - 28));
        header[236] = 99; header[237] = 130; header[238] = 83; header[239] = 99;

        List<byte> response = new List<byte>(header);
        NICChangerDhcpProtocol.AddOption(response, 53, new byte[] { messageType });
        NICChangerDhcpProtocol.AddOption(response, 54, _serverAddress.GetAddressBytes());
        if (messageType != 6)
        {
            NICChangerDhcpProtocol.AddOption(response, 51, NICChangerDhcpProtocol.UInt32Bytes(_leaseSeconds));
            NICChangerDhcpProtocol.AddOption(response, 58, NICChangerDhcpProtocol.UInt32Bytes(_leaseSeconds / 2));
            NICChangerDhcpProtocol.AddOption(response, 59, NICChangerDhcpProtocol.UInt32Bytes((_leaseSeconds * 7) / 8));
            NICChangerDhcpProtocol.AddOption(response, 1, _subnetMask.GetAddressBytes());
            if (_router != null) NICChangerDhcpProtocol.AddOption(response, 3, _router.GetAddressBytes());
            NICChangerDhcpProtocol.AddOption(response, 6, NICChangerDhcpProtocol.AddressListBytes(_dnsServers));
            NICChangerDhcpProtocol.AddOption(response, 42, NICChangerDhcpProtocol.AddressListBytes(_ntpServers));
            if (!String.IsNullOrWhiteSpace(_domainName))
                NICChangerDhcpProtocol.AddOption(response, 15, Encoding.ASCII.GetBytes(_domainName));
        }
        response.Add(255);
        byte[] packet = response.ToArray();
        _socket.SendTo(packet, new IPEndPoint(_broadcastAddress, 68));
    }

    public void Dispose()
    {
        Stop();
    }
}
"@
}

Add-Type -AssemblyName System.Windows.Forms


# Comment out to show console for debugging
[NICChangerNativeV2]::HideConsole()


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



$themeRegistryPath = 'HKCU:\Software\NICChanger'

function Get-SavedTheme {
    try {
        $savedTheme = (Get-ItemProperty -Path $themeRegistryPath -Name Theme -ErrorAction Stop).Theme
        if ($savedTheme -in @('Light', 'Dark')) {
            return $savedTheme
        }
    }
    catch {
        # Use the default when no preference has been saved yet.
    }
    return 'Dark'
}

function Set-ThemePalette {
    param([ValidateSet('Light', 'Dark')][string]$Mode)

    $script:themeMode = $Mode
    if ([System.Windows.Forms.SystemInformation]::HighContrast) {
        $script:colorBackground = [System.Drawing.SystemColors]::Window
        $script:colorSurface = [System.Drawing.SystemColors]::Control
        $script:colorCard = [System.Drawing.SystemColors]::ControlLight
        $script:colorInput = [System.Drawing.SystemColors]::Window
        $script:colorBorder = [System.Drawing.SystemColors]::ActiveBorder
        $script:colorText = [System.Drawing.SystemColors]::WindowText
        $script:colorMuted = [System.Drawing.SystemColors]::GrayText
        $script:colorAccent = [System.Drawing.SystemColors]::Highlight
        $script:colorAccentHover = [System.Drawing.SystemColors]::HotTrack
        $script:colorSuccess = [System.Drawing.SystemColors]::WindowText
        $script:colorFailure = [System.Drawing.SystemColors]::WindowText
        $script:colorWarning = [System.Drawing.SystemColors]::WindowText
    }
    elseif ($Mode -eq 'Light') {
        $script:colorBackground = [System.Drawing.ColorTranslator]::FromHtml('#F3F5F8')
        $script:colorSurface = [System.Drawing.ColorTranslator]::FromHtml('#FFFFFF')
        $script:colorCard = [System.Drawing.ColorTranslator]::FromHtml('#E7ECF3')
        $script:colorInput = [System.Drawing.ColorTranslator]::FromHtml('#F8FAFC')
        $script:colorBorder = [System.Drawing.ColorTranslator]::FromHtml('#CBD3DE')
        $script:colorText = [System.Drawing.ColorTranslator]::FromHtml('#172033')
        $script:colorMuted = [System.Drawing.ColorTranslator]::FromHtml('#5D6878')
        $script:colorAccent = [System.Drawing.ColorTranslator]::FromHtml('#2563EB')
        $script:colorAccentHover = [System.Drawing.ColorTranslator]::FromHtml('#1D4ED8')
        $script:colorSuccess = [System.Drawing.ColorTranslator]::FromHtml('#16845B')
        $script:colorFailure = [System.Drawing.ColorTranslator]::FromHtml('#D9364F')
        $script:colorWarning = [System.Drawing.ColorTranslator]::FromHtml('#9A6400')
    }
    else {
        $script:colorBackground = [System.Drawing.ColorTranslator]::FromHtml('#111318')
        $script:colorSurface = [System.Drawing.ColorTranslator]::FromHtml('#1A1D24')
        $script:colorCard = [System.Drawing.ColorTranslator]::FromHtml('#232731')
        $script:colorInput = [System.Drawing.ColorTranslator]::FromHtml('#16191F')
        $script:colorBorder = [System.Drawing.ColorTranslator]::FromHtml('#343A46')
        $script:colorText = [System.Drawing.ColorTranslator]::FromHtml('#F3F5F7')
        $script:colorMuted = [System.Drawing.ColorTranslator]::FromHtml('#9AA3B2')
        $script:colorAccent = [System.Drawing.ColorTranslator]::FromHtml('#4C8DFF')
        $script:colorAccentHover = [System.Drawing.ColorTranslator]::FromHtml('#367AE8')
        $script:colorSuccess = [System.Drawing.ColorTranslator]::FromHtml('#3DDC97')
        $script:colorFailure = [System.Drawing.ColorTranslator]::FromHtml('#FF647C')
        $script:colorWarning = [System.Drawing.ColorTranslator]::FromHtml('#F7C948')
    }
}

Set-ThemePalette -Mode (Get-SavedTheme)

function Set-ButtonStyle {
    param(
        [System.Windows.Forms.Button]$Button,
        [System.Drawing.Color]$BackColor = $colorCard,
        [System.Drawing.Color]$HoverColor = $colorBorder
    )

    $Button.BackColor = $BackColor
    $Button.ForeColor = $colorText
    $Button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $Button.FlatAppearance.BorderSize = 0
    $Button.FlatAppearance.MouseOverBackColor = $HoverColor
    $Button.FlatAppearance.MouseDownBackColor = $colorAccent
    $Button.Cursor = [System.Windows.Forms.Cursors]::Hand
    $Button.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9)
}

function New-StatusCard {
    param(
        [string]$Title,
        [int]$X,
        [int]$Width = 216
    )

    $panel = New-Object System.Windows.Forms.Panel
    $panel.Location = New-Object System.Drawing.Point($X, 0)
    $panel.Size = New-Object System.Drawing.Size($Width, 104)
    $panel.BackColor = $colorCard

    # Keep enough horizontal room for single-word states such as "Connected"
    # and "Unavailable". The previous 58 px text offset plus right padding left
    # only 84 px in the dashboard cards, which could split a word at some DPI
    # and font-scaling settings.
    $textLeft = 50
    $valueWidth = [Math]::Max(70, $Width - $textLeft - 12)

    $icon = New-Object System.Windows.Forms.Label
    $icon.Location = New-Object System.Drawing.Point(12, 16)
    $icon.Size = New-Object System.Drawing.Size(30, 34)
    $icon.Font = New-Object System.Drawing.Font('Segoe UI Symbol', 18, [System.Drawing.FontStyle]::Bold)
    $icon.ForeColor = $colorMuted
    $icon.Text = ([char]0x2022).ToString()
    $icon.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter

    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Location = New-Object System.Drawing.Point($textLeft, 18)
    $titleLabel.Size = New-Object System.Drawing.Size($valueWidth, 18)
    $titleLabel.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9)
    $titleLabel.ForeColor = $colorMuted
    $titleLabel.Text = $Title.ToUpperInvariant()

    $value = New-Object System.Windows.Forms.Label
    $value.Location = New-Object System.Drawing.Point($textLeft, 41)
    $value.Size = New-Object System.Drawing.Size($valueWidth, 42)
    $value.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 12)
    $value.ForeColor = $colorText
    $value.Text = 'Not checked'

    $panel.Controls.Add($icon)
    $panel.Controls.Add($titleLabel)
    $panel.Controls.Add($value)

    return [PSCustomObject]@{ Panel = $panel; Icon = $icon; Title = $titleLabel; Value = $value; State = 'Neutral' }
}

function Set-StatusCard {
    param(
        [PSCustomObject]$Card,
        [string]$Text,
        [ValidateSet('Neutral', 'Pending', 'Success', 'Failure')]
        [string]$State = 'Neutral'
    )

    $Card.Value.Text = $Text
    $Card.State = $State
    $Card.Value.AccessibleName = "$($Card.Title.Text) status: $Text"
    $Card.Icon.AccessibleName = "$($Card.Title.Text) status indicator: $State"
    switch ($State) {
        'Pending' {
            $Card.Icon.Text = ([char]0x2026).ToString()
            $Card.Icon.ForeColor = $colorWarning
            $Card.Value.ForeColor = $colorWarning
        }
        'Success' {
            $Card.Icon.Text = ([char]0x2713).ToString()
            $Card.Icon.ForeColor = $colorSuccess
            $Card.Value.ForeColor = $colorSuccess
        }
        'Failure' {
            $Card.Icon.Text = ([char]0x2715).ToString()
            $Card.Icon.ForeColor = $colorFailure
            $Card.Value.ForeColor = $colorFailure
        }
        default {
            $Card.Icon.Text = ([char]0x2022).ToString()
            $Card.Icon.ForeColor = $colorMuted
            $Card.Value.ForeColor = $colorText
        }
    }
}

function Convert-PrefixToSubnetMask {
    param([int]$PrefixLength)

    if ($PrefixLength -lt 0 -or $PrefixLength -gt 32) {
        return $null
    }

    $octets = for ($octetIndex = 0; $octetIndex -lt 4; $octetIndex++) {
        $bitsInOctet = [Math]::Min(8, [Math]::Max(0, $PrefixLength - ($octetIndex * 8)))
        if ($bitsInOctet -eq 0) {
            0
        }
        else {
            256 - [Math]::Pow(2, 8 - $bitsInOctet)
        }
    }

    return $octets -join '.'
}

function Convert-SubnetMaskToPrefix {
    param([string]$SubnetMask)

    $octets = $SubnetMask.Trim().Split('.')
    if ($octets.Count -ne 4) {
        return $null
    }

    $binaryMask = ''
    foreach ($octet in $octets) {
        $value = 0
        if (-not [int]::TryParse($octet, [ref]$value) -or $value -lt 0 -or $value -gt 255) {
            return $null
        }
        $binaryMask += [Convert]::ToString($value, 2).PadLeft(8, '0')
    }

    if ($binaryMask -notmatch '^1*0*$') {
        return $null
    }

    $firstZero = $binaryMask.IndexOf('0')
    return $(if ($firstZero -eq -1) { 32 } else { $firstZero })
}

function Test-ValidIPv4Address {
    param([string]$Address)

    if ([string]::IsNullOrWhiteSpace($Address) -or $Address -notmatch '^\d{1,3}(\.\d{1,3}){3}$') {
        return $false
    }

    $parsedAddress = $null
    if (-not [System.Net.IPAddress]::TryParse($Address, [ref]$parsedAddress)) {
        return $false
    }

    return $parsedAddress.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork
}

function Convert-IPv4ToUInt32 {
    param([string]$Address)

    $bytes = [System.Net.IPAddress]::Parse($Address).GetAddressBytes()
    return [uint64]$bytes[0] * 16777216 + [uint64]$bytes[1] * 65536 + [uint64]$bytes[2] * 256 + [uint64]$bytes[3]
}

function Convert-UInt32ToIPv4 {
    param([uint64]$Value)

    return '{0}.{1}.{2}.{3}' -f (
        [Math]::Floor($Value / 16777216) % 256
    ), (
        [Math]::Floor($Value / 65536) % 256
    ), (
        [Math]::Floor($Value / 256) % 256
    ), ($Value % 256)
}

function Get-AdapterContext {
    param(
        [object]$InterfaceInfo,
        [object[]]$VMSwitches = @(),
        [switch]$InspectHyperVSwitches
    )

    $alias = $InterfaceInfo.InterfaceAlias
    $description = $InterfaceInfo.InterfaceDescription
    $isVirtual = $InterfaceInfo.Virtual -eq $true -or $description -match 'Virtual|Hyper-V'
    $displayText = if ($isVirtual) { 'Virtual network adapter' } else { 'Physical network adapter' }
    $canConfigure = $true
    $notice = ''

    if ($alias -match '^vEthernet \((.+)\)$') {
        $switchName = $Matches[1]
        $displayText = "Hyper-V vEthernet - $switchName"

        if ($InspectHyperVSwitches) {
            $vmSwitch = $VMSwitches | Where-Object { $_.Name -eq $switchName } | Select-Object -First 1
            if ($vmSwitch) {
                $displayText = "Hyper-V $($vmSwitch.SwitchType) switch - $switchName"
            }
        }
    }
    elseif ($InspectHyperVSwitches) {
        $uplinkSwitch = $VMSwitches |
        Where-Object { $_.SwitchType -eq 'External' -and $_.NetAdapterInterfaceDescription -eq $description } |
        Select-Object -First 1

        if ($uplinkSwitch) {
            $displayText = "Hyper-V uplink - $($uplinkSwitch.Name)"
            $canConfigure = $false
            $notice = "Configure vEthernet ($($uplinkSwitch.Name)) instead of this switch uplink."
        }
    }

    return [PSCustomObject]@{
        DisplayText    = $displayText
        CanConfigure   = $canConfigure
        IsSwitchUplink = -not $canConfigure -and $displayText -like 'Hyper-V uplink*'
        Notice         = $notice
    }
}

function New-AddressRow {
    param(
        [System.Windows.Forms.Control]$Parent,
        [string]$Title,
        [int]$Y
    )

    $row = New-Object System.Windows.Forms.Panel
    $row.Location = New-Object System.Drawing.Point(16, $Y)
    $row.Size = New-Object System.Drawing.Size(648, 30)
    $row.BackColor = $colorInput

    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Location = New-Object System.Drawing.Point(12, 6)
    $titleLabel.Size = New-Object System.Drawing.Size(102, 18)
    $titleLabel.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9)
    $titleLabel.ForeColor = $colorMuted
    $titleLabel.Text = $Title

    $value = New-Object System.Windows.Forms.Label
    $value.Location = New-Object System.Drawing.Point(120, 5)
    $value.Size = New-Object System.Drawing.Size(514, 22)
    $value.Font = New-Object System.Drawing.Font('Consolas', 9)
    $value.ForeColor = $colorText
    $value.Text = ([char]0x2014).ToString()
    $value.AutoEllipsis = $true
    $value.AccessibleName = "$Title value"

    $row.Controls.Add($titleLabel)
    $row.Controls.Add($value)
    $Parent.Controls.Add($row)
    return $value
}

# Main window
$form = New-Object System.Windows.Forms.Form
$form.Text = 'NIC Changer'
$form.ClientSize = New-Object System.Drawing.Size(1020, 692)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedSingle
$form.MaximizeBox = $false
$form.BackColor = $colorBackground
$form.ForeColor = $colorText
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi

$scriptDirectory = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) { $PSScriptRoot } else { (Get-Location).Path }
$appIconPath = Join-Path $scriptDirectory 'assets\nic-changer.ico'
if (Test-Path -LiteralPath $appIconPath) {
    try {
        # Keep the icon object alive for the lifetime of the form.
        $script:appIcon = New-Object System.Drawing.Icon($appIconPath)
        $form.Icon = $script:appIcon
    }
    catch {
        Write-Host "Unable to load application icon: $_"
    }
}
else {
    try {
        # Packaged builds carry the icon in the executable rather than an assets folder.
        $processPath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $script:appIcon = [System.Drawing.Icon]::ExtractAssociatedIcon($processPath)
        if ($null -ne $script:appIcon) {
            $form.Icon = $script:appIcon
        }
    }
    catch {
        Write-Host "Unable to load the embedded application icon: $_"
    }
}

# Header
$headerPanel = New-Object System.Windows.Forms.Panel
$headerPanel.Dock = [System.Windows.Forms.DockStyle]::Top
$headerPanel.Height = 70
$headerPanel.BackColor = $colorSurface

$logoLabel = New-Object System.Windows.Forms.Label
$logoLabel.Location = New-Object System.Drawing.Point(20, 17)
$logoLabel.Size = New-Object System.Drawing.Size(38, 38)
$logoLabel.BackColor = $colorAccent
$logoLabel.ForeColor = [System.Drawing.Color]::White
$logoLabel.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 11)
$logoLabel.Text = 'NC'
$logoLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter

$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Location = New-Object System.Drawing.Point(70, 13)
$titleLabel.Size = New-Object System.Drawing.Size(260, 28)
$titleLabel.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 16)
$titleLabel.ForeColor = $colorText
$titleLabel.Text = 'NIC Changer'

$subtitleLabel = New-Object System.Windows.Forms.Label
$subtitleLabel.Location = New-Object System.Drawing.Point(72, 42)
$subtitleLabel.Size = New-Object System.Drawing.Size(350, 18)
$subtitleLabel.ForeColor = $colorMuted
$subtitleLabel.Text = 'Network adapter configuration and diagnostics'

$adminBadge = New-Object System.Windows.Forms.Label
$adminBadge.Location = New-Object System.Drawing.Point(858, 23)
$adminBadge.Size = New-Object System.Drawing.Size(140, 26)
$adminBadge.BackColor = $colorCard
$adminBadge.ForeColor = $colorSuccess
$adminBadge.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 8)
$adminBadge.Text = ([char]0x2713).ToString() + '  ADMINISTRATOR'
$adminBadge.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter

$btnTheme = New-Object System.Windows.Forms.Button
$btnTheme.Location = New-Object System.Drawing.Point(742, 20)
$btnTheme.Size = New-Object System.Drawing.Size(102, 32)
$btnTheme.Text = if ($script:themeMode -eq 'Dark') { ([char]0x2600).ToString() + '  &Light' } else { ([char]0x263E).ToString() + '  &Dark' }
Set-ButtonStyle -Button $btnTheme
$btnTheme.Add_Click({
        $nextTheme = if ($script:themeMode -eq 'Dark') { 'Light' } else { 'Dark' }
        Apply-AppTheme -Mode $nextTheme -Persist
    })

$headerPanel.Controls.Add($logoLabel)
$headerPanel.Controls.Add($titleLabel)
$headerPanel.Controls.Add($subtitleLabel)
$headerPanel.Controls.Add($btnTheme)
$headerPanel.Controls.Add($adminBadge)
$form.Controls.Add($headerPanel)

# Adapter navigation
$sidebarPanel = New-Object System.Windows.Forms.Panel
$sidebarPanel.Location = New-Object System.Drawing.Point(20, 88)
$sidebarPanel.Size = New-Object System.Drawing.Size(270, 584)
$sidebarPanel.BackColor = $colorSurface

$adapterHeading = New-Object System.Windows.Forms.Label
$adapterHeading.Location = New-Object System.Drawing.Point(16, 16)
$adapterHeading.Size = New-Object System.Drawing.Size(170, 24)
$adapterHeading.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 12)
$adapterHeading.ForeColor = $colorText
$adapterHeading.Text = 'Network adapters'

$adapterHint = New-Object System.Windows.Forms.Label
$adapterHint.Location = New-Object System.Drawing.Point(16, 43)
$adapterHint.Size = New-Object System.Drawing.Size(238, 34)
$adapterHint.ForeColor = $colorMuted
$adapterHint.Text = 'Choose an adapter to inspect and configure.'

$checkHideUplinks = New-Object System.Windows.Forms.CheckBox
$checkHideUplinks.Location = New-Object System.Drawing.Point(16, 80)
$checkHideUplinks.Size = New-Object System.Drawing.Size(238, 24)
$checkHideUplinks.Text = '&Hide Hyper-V switch uplinks'
$checkHideUplinks.Checked = $false
$checkHideUplinks.ForeColor = $colorMuted
$checkHideUplinks.UseVisualStyleBackColor = $false
$checkHideUplinks.Add_CheckedChanged({
        if (-not $script:suppressAdapterFilterEvent) {
            Update-AdapterFilter
        }
    })

$adapterListPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$adapterListPanel.Location = New-Object System.Drawing.Point(16, 108)
$adapterListPanel.Size = New-Object System.Drawing.Size(238, 410)
$adapterListPanel.BackColor = $colorInput
$adapterListPanel.AutoScroll = $true
$adapterListPanel.FlowDirection = [System.Windows.Forms.FlowDirection]::TopDown
$adapterListPanel.WrapContents = $false
$adapterListPanel.Padding = New-Object System.Windows.Forms.Padding(5)

$btnRefresh = New-Object System.Windows.Forms.Button
$btnRefresh.Location = New-Object System.Drawing.Point(16, 532)
$btnRefresh.Size = New-Object System.Drawing.Size(238, 36)
$btnRefresh.Text = ([char]0x21BB).ToString() + '  &Refresh adapters'
Set-ButtonStyle -Button $btnRefresh
$btnRefresh.Add_Click({ Get-NetworkInterface })

$sidebarPanel.Controls.Add($adapterHeading)
$sidebarPanel.Controls.Add($adapterHint)
$sidebarPanel.Controls.Add($checkHideUplinks)
$sidebarPanel.Controls.Add($adapterListPanel)
$sidebarPanel.Controls.Add($btnRefresh)
$form.Controls.Add($sidebarPanel)

# Dashboard area
$contentPanel = New-Object System.Windows.Forms.Panel
$contentPanel.Location = New-Object System.Drawing.Point(310, 88)
$contentPanel.Size = New-Object System.Drawing.Size(690, 584)
$contentPanel.BackColor = $colorBackground

$adapterStatusCard = New-StatusCard -Title 'Adapter' -X 0 -Width 164
$internetStatusCard = New-StatusCard -Title 'Internet' -X 172 -Width 164
$dnsStatusCard = New-StatusCard -Title 'DNS' -X 344 -Width 164
$dhcpStatusCard = New-StatusCard -Title 'DHCP' -X 516 -Width 164
$contentPanel.Controls.Add($adapterStatusCard.Panel)
$contentPanel.Controls.Add($internetStatusCard.Panel)
$contentPanel.Controls.Add($dnsStatusCard.Panel)
$contentPanel.Controls.Add($dhcpStatusCard.Panel)

# Address details card
$addressPanel = New-Object System.Windows.Forms.Panel
$addressPanel.Location = New-Object System.Drawing.Point(0, 120)
$addressPanel.Size = New-Object System.Drawing.Size(680, 206)
$addressPanel.BackColor = $colorSurface

$addressHeading = New-Object System.Windows.Forms.Label
$addressHeading.Location = New-Object System.Drawing.Point(16, 12)
$addressHeading.Size = New-Object System.Drawing.Size(250, 22)
$addressHeading.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 11)
$addressHeading.ForeColor = $colorText
$addressHeading.Text = 'Address details'
$addressPanel.Controls.Add($addressHeading)

$btnScanSubnet = New-Object System.Windows.Forms.Button
$btnScanSubnet.Location = New-Object System.Drawing.Point(500, 8)
$btnScanSubnet.Size = New-Object System.Drawing.Size(164, 28)
$btnScanSubnet.Text = '&Scan subnet'
$btnScanSubnet.Enabled = $false
Set-ButtonStyle -Button $btnScanSubnet
$btnScanSubnet.Add_Click({ Start-SubnetScan })
$addressPanel.Controls.Add($btnScanSubnet)

$lblAdapterTypeValue = New-AddressRow -Parent $addressPanel -Title 'ADAPTER TYPE' -Y 38
$lblMacAddressValue = New-AddressRow -Parent $addressPanel -Title 'MAC ADDRESS' -Y 70
$lblIPv4Value = New-AddressRow -Parent $addressPanel -Title 'IPv4 ADDRESS' -Y 102
$lblPrefixValue = New-AddressRow -Parent $addressPanel -Title 'PREFIX LENGTH' -Y 134
$lblIPv6Value = New-AddressRow -Parent $addressPanel -Title 'IPv6 ADDRESS' -Y 166
$contentPanel.Controls.Add($addressPanel)

# Configuration card
$configPanel = New-Object System.Windows.Forms.Panel
$configPanel.Location = New-Object System.Drawing.Point(0, 342)
$configPanel.Size = New-Object System.Drawing.Size(680, 242)
$configPanel.BackColor = $colorSurface

$configHeading = New-Object System.Windows.Forms.Label
$configHeading.Location = New-Object System.Drawing.Point(16, 12)
$configHeading.Size = New-Object System.Drawing.Size(250, 24)
$configHeading.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 11)
$configHeading.ForeColor = $colorText
$configHeading.Text = 'IPv4 configuration'

$configNoticeLabel = New-Object System.Windows.Forms.Label
$configNoticeLabel.Location = New-Object System.Drawing.Point(245, 13)
$configNoticeLabel.Size = New-Object System.Drawing.Size(419, 34)
$configNoticeLabel.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 8)
$configNoticeLabel.ForeColor = $colorWarning
$configNoticeLabel.TextAlign = [System.Drawing.ContentAlignment]::TopRight
$configNoticeLabel.Text = ''

$ipInputLabel = New-Object System.Windows.Forms.Label
$ipInputLabel.Location = New-Object System.Drawing.Point(16, 46)
$ipInputLabel.Size = New-Object System.Drawing.Size(220, 18)
$ipInputLabel.ForeColor = $colorMuted
$ipInputLabel.Text = '&IP ADDRESS'

$textBoxCapturedIP = New-Object System.Windows.Forms.TextBox
$textBoxCapturedIP.Location = New-Object System.Drawing.Point(16, 67)
$textBoxCapturedIP.Size = New-Object System.Drawing.Size(216, 28)
$textBoxCapturedIP.BackColor = $colorInput
$textBoxCapturedIP.ForeColor = $colorText
$textBoxCapturedIP.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$textBoxCapturedIP.Font = New-Object System.Drawing.Font('Consolas', 10)
$textBoxCapturedIP.Text = ''
$textBoxCapturedIP.Add_TextChanged({
        $selectedInterface = $script:selectedInterface
        $enteredIP = $textBoxCapturedIP.Text.Trim()

        if ($selectedInterface) {
            if (-not (Test-ValidIPv4Address -Address $enteredIP)) {
                $CapturedIPs.Remove($selectedInterface)
            }
            else {
                $CapturedIPs[$selectedInterface] = $enteredIP
            }
        }
        Update-CapturedIPButton
    })

$subnetInputLabel = New-Object System.Windows.Forms.Label
$subnetInputLabel.Location = New-Object System.Drawing.Point(248, 46)
$subnetInputLabel.Size = New-Object System.Drawing.Size(144, 18)
$subnetInputLabel.ForeColor = $colorMuted
$subnetInputLabel.Text = '&SUBNET MASK'

$textBoxCapturedSubnet = New-Object System.Windows.Forms.TextBox
$textBoxCapturedSubnet.Location = New-Object System.Drawing.Point(248, 67)
$textBoxCapturedSubnet.Size = New-Object System.Drawing.Size(144, 28)
$textBoxCapturedSubnet.BackColor = $colorInput
$textBoxCapturedSubnet.ForeColor = $colorText
$textBoxCapturedSubnet.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$textBoxCapturedSubnet.Font = New-Object System.Drawing.Font('Consolas', 10)
$textBoxCapturedSubnet.Text = '255.255.255.0'

$cidrInputLabel = New-Object System.Windows.Forms.Label
$cidrInputLabel.Location = New-Object System.Drawing.Point(400, 46)
$cidrInputLabel.Size = New-Object System.Drawing.Size(64, 18)
$cidrInputLabel.ForeColor = $colorMuted
$cidrInputLabel.Text = '&CIDR'

$comboCidr = New-Object System.Windows.Forms.ComboBox
$comboCidr.Location = New-Object System.Drawing.Point(400, 65)
$comboCidr.Size = New-Object System.Drawing.Size(64, 28)
$comboCidr.BackColor = $colorInput
$comboCidr.ForeColor = $colorText
$comboCidr.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$comboCidr.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$comboCidr.Font = New-Object System.Drawing.Font('Consolas', 10)
for ($prefix = 0; $prefix -le 32; $prefix++) {
    $comboCidr.Items.Add("/$prefix") | Out-Null
}
$comboCidr.SelectedItem = '/24'

$script:updatingSubnetFields = $false
$comboCidr.Add_SelectedIndexChanged({
        if (-not $script:updatingSubnetFields -and $comboCidr.SelectedIndex -ge 0) {
            $script:updatingSubnetFields = $true
            $textBoxCapturedSubnet.Text = Convert-PrefixToSubnetMask -PrefixLength $comboCidr.SelectedIndex
            $textBoxCapturedSubnet.ForeColor = $colorText
            $textBoxCapturedSubnet.AccessibleDescription = "Valid subnet mask for CIDR prefix $($comboCidr.SelectedItem)."
            if ($null -ne $validationErrors) {
                $validationErrors.SetError($textBoxCapturedSubnet, '')
            }
            $script:updatingSubnetFields = $false
        }
    })
$textBoxCapturedSubnet.Add_TextChanged({
        if (-not $script:updatingSubnetFields) {
            $prefix = Convert-SubnetMaskToPrefix -SubnetMask $textBoxCapturedSubnet.Text
            $script:updatingSubnetFields = $true
            if ($null -ne $prefix) {
                $comboCidr.SelectedIndex = $prefix
                $textBoxCapturedSubnet.ForeColor = $colorText
                $textBoxCapturedSubnet.AccessibleDescription = 'Valid subnet mask. You can also choose a CIDR prefix.'
                if ($null -ne $validationErrors) {
                    $validationErrors.SetError($textBoxCapturedSubnet, '')
                }
            }
            else {
                $comboCidr.SelectedIndex = -1
                $textBoxCapturedSubnet.ForeColor = $colorFailure
                $textBoxCapturedSubnet.AccessibleDescription = 'Invalid subnet mask. Enter a contiguous mask such as 255.255.255.0.'
                if ($null -ne $validationErrors) {
                    $validationErrors.SetError($textBoxCapturedSubnet, 'Enter a valid contiguous subnet mask.')
                }
            }
            $script:updatingSubnetFields = $false
        }
    })

$btnCaptureIP = New-Object System.Windows.Forms.Button
$btnCaptureIP.Location = New-Object System.Drawing.Point(480, 65)
$btnCaptureIP.Size = New-Object System.Drawing.Size(184, 32)
$btnCaptureIP.Text = '&Capture current IPv4'
Set-ButtonStyle -Button $btnCaptureIP
$btnCaptureIP.Add_Click({ Capture-Current-IPv4 })

$btnCaptureIPtoSet = New-Object System.Windows.Forms.Button
$btnCaptureIPtoSet.Location = New-Object System.Drawing.Point(16, 112)
$btnCaptureIPtoSet.Size = New-Object System.Drawing.Size(648, 38)
$btnCaptureIPtoSet.Text = '&Enter an IP address to set static IPv4'
$btnCaptureIPtoSet.Enabled = $false
Set-ButtonStyle -Button $btnCaptureIPtoSet -BackColor $colorAccent -HoverColor $colorAccentHover
$btnCaptureIPtoSet.Add_Click({ Set-Captured-IP })

$btnSetDhcpLinkLocal = New-Object System.Windows.Forms.Button
$btnSetDhcpLinkLocal.Location = New-Object System.Drawing.Point(16, 166)
$btnSetDhcpLinkLocal.Size = New-Object System.Drawing.Size(210, 42)
$btnSetDhcpLinkLocal.Text = '&Use automatic addressing (DHCP)'
Set-ButtonStyle -Button $btnSetDhcpLinkLocal
$btnSetDhcpLinkLocal.Add_Click({ Set-DHCP-LinkLocal-IP })

$btnSetLinkLocal = New-Object System.Windows.Forms.Button
$btnSetLinkLocal.Location = New-Object System.Drawing.Point(235, 166)
$btnSetLinkLocal.Size = New-Object System.Drawing.Size(210, 42)
$btnSetLinkLocal.Text = '&Generate link-local address'
Set-ButtonStyle -Button $btnSetLinkLocal
$btnSetLinkLocal.Add_Click({ Set-RandomLinkLocal-IP })

$btnDhcpServer = New-Object System.Windows.Forms.Button
$btnDhcpServer.Location = New-Object System.Drawing.Point(454, 166)
$btnDhcpServer.Size = New-Object System.Drawing.Size(210, 42)
$btnDhcpServer.Text = '&Enable DHCP Server'
Set-ButtonStyle -Button $btnDhcpServer
$btnDhcpServer.Add_Click({ Show-DhcpServerDialog })

$configPanel.Controls.Add($configHeading)
$configPanel.Controls.Add($configNoticeLabel)
$configPanel.Controls.Add($ipInputLabel)
$configPanel.Controls.Add($textBoxCapturedIP)
$configPanel.Controls.Add($subnetInputLabel)
$configPanel.Controls.Add($textBoxCapturedSubnet)
$configPanel.Controls.Add($cidrInputLabel)
$configPanel.Controls.Add($comboCidr)
$configPanel.Controls.Add($btnCaptureIP)
$configPanel.Controls.Add($btnCaptureIPtoSet)
$configPanel.Controls.Add($btnSetDhcpLinkLocal)
$configPanel.Controls.Add($btnSetLinkLocal)
$configPanel.Controls.Add($btnDhcpServer)
$contentPanel.Controls.Add($configPanel)
$form.Controls.Add($contentPanel)

# Accessibility metadata, keyboard navigation, and non-color validation cues.
$form.AccessibleName = 'NIC Changer network configuration utility'
$form.AccessibleDescription = 'Inspect network adapters, test connectivity, and configure IPv4 settings.'
$form.KeyPreview = $true

$headerPanel.AccessibleName = 'Application header'
$sidebarPanel.AccessibleName = 'Network adapter selection'
$addressPanel.AccessibleName = 'Address details'
$configPanel.AccessibleName = 'IPv4 configuration'
foreach ($panel in @($headerPanel, $sidebarPanel, $addressPanel, $configPanel)) {
    $panel.AccessibleRole = [System.Windows.Forms.AccessibleRole]::Grouping
}

$adapterStatusCard.Panel.AccessibleName = 'Adapter status'
$internetStatusCard.Panel.AccessibleName = 'Internet connectivity status'
$dnsStatusCard.Panel.AccessibleName = 'DNS resolution status'
$dhcpStatusCard.Panel.AccessibleName = 'DHCP server status'
foreach ($card in @($adapterStatusCard, $internetStatusCard, $dnsStatusCard, $dhcpStatusCard)) {
    $card.Panel.AccessibleRole = [System.Windows.Forms.AccessibleRole]::Grouping
    $card.Value.AccessibleRole = [System.Windows.Forms.AccessibleRole]::StaticText
    $card.Icon.AccessibleRole = [System.Windows.Forms.AccessibleRole]::Graphic
}
$liveSettingProperty = [System.Windows.Forms.Label].GetProperty('LiveSetting')
if ($null -ne $liveSettingProperty) {
    $politeSetting = [System.Enum]::Parse($liveSettingProperty.PropertyType, 'Polite')
    foreach ($statusValue in @($adapterStatusCard.Value, $internetStatusCard.Value, $dnsStatusCard.Value, $dhcpStatusCard.Value, $configNoticeLabel)) {
        $liveSettingProperty.SetValue($statusValue, $politeSetting, $null)
    }
}

$adapterListPanel.AccessibleName = 'Network adapters'
$adapterListPanel.AccessibleDescription = 'Scrollable list of network adapter buttons.'
$adapterListPanel.AccessibleRole = [System.Windows.Forms.AccessibleRole]::Grouping
$checkHideUplinks.AccessibleName = 'Hide Hyper-V switch uplinks'
$checkHideUplinks.AccessibleDescription = 'Filters physical adapters reserved as uplinks for external Hyper-V switches.'
$textBoxCapturedIP.AccessibleName = 'Static IPv4 address'
$textBoxCapturedIP.AccessibleDescription = 'Enter four numbers from 0 to 255 separated by periods.'
$textBoxCapturedSubnet.AccessibleName = 'Subnet mask'
$textBoxCapturedSubnet.AccessibleDescription = 'Enter a dotted-decimal subnet mask or choose a CIDR prefix.'
$comboCidr.AccessibleName = 'CIDR prefix length'
$comboCidr.AccessibleDescription = 'Choose a prefix length from slash zero through slash thirty-two.'
$adminBadge.AccessibleName = 'Running with administrator privileges'
$configNoticeLabel.AccessibleName = 'Adapter configuration notice'
$btnTheme.AccessibleName = 'Switch color theme'
$btnRefresh.AccessibleName = 'Refresh network adapters'
$btnCaptureIP.AccessibleName = 'Capture current IPv4 address'
$btnCaptureIPtoSet.AccessibleName = 'Apply static IPv4 address'
$btnSetDhcpLinkLocal.AccessibleName = 'Use automatic DHCP addressing'
$btnSetLinkLocal.AccessibleName = 'Generate a link-local address'
$btnDhcpServer.AccessibleName = 'Enable DHCP Server'
$btnScanSubnet.AccessibleName = 'Scan selected adapter subnet'
$btnScanSubnet.AccessibleDescription = 'Ping the selected IPv4 subnet, then look up hostnames only for responding addresses.'
$btnCaptureIPtoSet.AccessibleDescription = 'Validates and checks the address for conflicts before changing the selected adapter.'
$btnSetDhcpLinkLocal.AccessibleDescription = 'Changes the selected adapter to automatic IPv4 addressing.'
$btnSetLinkLocal.AccessibleDescription = 'Assigns an available address in the 169.254.0.0 slash 16 range.'
$btnDhcpServer.AccessibleDescription = 'Checks for another DHCP server and address conflicts before opening a temporary DHCP server on the selected adapter.'

$sidebarPanel.TabIndex = 0
$contentPanel.TabIndex = 1
$headerPanel.TabIndex = 2
$checkHideUplinks.TabIndex = 0
$adapterListPanel.TabIndex = 1
$btnRefresh.TabIndex = 2
$textBoxCapturedIP.TabIndex = 2
$textBoxCapturedSubnet.TabIndex = 3
$comboCidr.TabIndex = 4
$btnCaptureIP.TabIndex = 5
$btnCaptureIPtoSet.TabIndex = 6
$btnSetDhcpLinkLocal.TabIndex = 7
$btnSetLinkLocal.TabIndex = 8
$btnDhcpServer.TabIndex = 9
$btnScanSubnet.TabIndex = 10
$btnTheme.TabIndex = 11

$toolTip = New-Object System.Windows.Forms.ToolTip
$toolTip.AutoPopDelay = 8000
$toolTip.InitialDelay = 400
$toolTip.ReshowDelay = 100
$toolTip.ShowAlways = $true
$toolTip.SetToolTip($checkHideUplinks, 'Show or hide physical adapters used as Hyper-V external-switch uplinks.')
$toolTip.SetToolTip($adapterListPanel, 'Scrollable network adapter list. Use Tab to move between adapter buttons.')
$toolTip.SetToolTip($btnRefresh, 'Refresh the adapter list (F5).')
$toolTip.SetToolTip($btnTheme, 'Switch between light and dark mode (Ctrl+D). Windows High Contrast takes precedence.')
$toolTip.SetToolTip($textBoxCapturedIP, 'Example: 192.168.1.25')
$toolTip.SetToolTip($textBoxCapturedSubnet, 'Example: 255.255.255.0')
$toolTip.SetToolTip($comboCidr, 'Example: /24 is equivalent to 255.255.255.0')
$toolTip.SetToolTip($btnScanSubnet, 'Discover responding IPv4 hosts and resolve their hostnames.')
$toolTip.SetToolTip($btnDhcpServer, 'Safely enable or manage the temporary DHCP server on the selected adapter.')

$validationErrors = New-Object System.Windows.Forms.ErrorProvider
$validationErrors.ContainerControl = $form
$validationErrors.BlinkStyle = [System.Windows.Forms.ErrorBlinkStyle]::NeverBlink
$validationErrors.SetIconAlignment($textBoxCapturedIP, [System.Windows.Forms.ErrorIconAlignment]::MiddleRight)
$validationErrors.SetIconAlignment($textBoxCapturedSubnet, [System.Windows.Forms.ErrorIconAlignment]::MiddleRight)

$form.Add_KeyDown({
        if ($_.KeyCode -eq [System.Windows.Forms.Keys]::F5 -and $btnRefresh.Enabled) {
            $_.SuppressKeyPress = $true
            Get-NetworkInterface
        }
        elseif ($_.Control -and $_.KeyCode -eq [System.Windows.Forms.Keys]::D -and $btnTheme.Enabled) {
            $_.SuppressKeyPress = $true
            $btnTheme.PerformClick()
        }
        elseif ($_.KeyCode -eq [System.Windows.Forms.Keys]::Escape) {
            $_.SuppressKeyPress = $true
            $form.Close()
        }
    })

$form.Add_SystemColorsChanged({
        Apply-AppTheme -Mode $script:themeMode
    })

function Apply-AppTheme {
    param(
        [ValidateSet('Light', 'Dark')][string]$Mode,
        [switch]$Persist
    )

    $form.SuspendLayout()
    try {
        Set-ThemePalette -Mode $Mode

        $form.BackColor = $colorBackground
        $form.ForeColor = $colorText
        $contentPanel.BackColor = $colorBackground

        foreach ($surface in @($headerPanel, $sidebarPanel, $addressPanel, $configPanel)) {
            $surface.BackColor = $colorSurface
        }
        foreach ($card in @($adapterStatusCard.Panel, $internetStatusCard.Panel, $dnsStatusCard.Panel, $dhcpStatusCard.Panel)) {
            $card.BackColor = $colorCard
        }
        foreach ($statusCard in @($adapterStatusCard, $internetStatusCard, $dnsStatusCard, $dhcpStatusCard)) {
            $statusCard.Title.ForeColor = $colorMuted
            Set-StatusCard -Card $statusCard -Text $statusCard.Value.Text -State $statusCard.State
        }

        foreach ($control in @($adapterListPanel, $textBoxCapturedIP, $textBoxCapturedSubnet, $comboCidr)) {
            $control.BackColor = $colorInput
            $control.ForeColor = $colorText
        }
        foreach ($row in @($addressPanel.Controls | Where-Object { $_ -is [System.Windows.Forms.Panel] })) {
            $row.BackColor = $colorInput
            $row.Controls[0].ForeColor = $colorMuted
            $row.Controls[1].ForeColor = $colorText
        }

        foreach ($label in @($titleLabel, $adapterHeading, $addressHeading, $configHeading)) {
            $label.ForeColor = $colorText
        }
        foreach ($label in @($subtitleLabel, $adapterHint, $ipInputLabel, $subnetInputLabel, $cidrInputLabel)) {
            $label.ForeColor = $colorMuted
        }
        $checkHideUplinks.ForeColor = $colorMuted

        $logoLabel.BackColor = $colorAccent
        $logoLabel.ForeColor = [System.Drawing.Color]::White
        $adminBadge.BackColor = $colorCard
        $adminBadge.ForeColor = $colorSuccess
        $configNoticeLabel.ForeColor = $colorWarning

        Set-ButtonStyle -Button $btnTheme
        Set-ButtonStyle -Button $btnRefresh
        Set-ButtonStyle -Button $btnCaptureIP
        Set-ButtonStyle -Button $btnSetDhcpLinkLocal
        Set-ButtonStyle -Button $btnSetLinkLocal
        Set-ButtonStyle -Button $btnDhcpServer
        Update-DhcpServerButton
        Set-ButtonStyle -Button $btnScanSubnet
        Set-ButtonStyle -Button $btnCaptureIPtoSet -BackColor $colorAccent -HoverColor $colorAccentHover
        $highContrastEnabled = [System.Windows.Forms.SystemInformation]::HighContrast
        $btnTheme.Enabled = -not $highContrastEnabled
        $btnTheme.Text = if ($highContrastEnabled) {
            'System contrast'
        }
        elseif ($Mode -eq 'Dark') {
            ([char]0x2600).ToString() + '  &Light'
        }
        else {
            ([char]0x263E).ToString() + '  &Dark'
        }
        $btnTheme.AccessibleDescription = if ($highContrastEnabled) {
            'Theme switching is unavailable while Windows High Contrast is active.'
        }
        else {
            'Switch between light and dark appearance. Keyboard shortcut Control plus D.'
        }

        Update-CapturedIPButton
        $subnetPrefix = Convert-SubnetMaskToPrefix -SubnetMask $textBoxCapturedSubnet.Text
        $textBoxCapturedSubnet.ForeColor = if ($null -eq $subnetPrefix) { $colorFailure } else { $colorText }

        if ($form.IsHandleCreated) {
            [NICChangerNativeV2]::SetDarkTitleBar($form.Handle, -not $highContrastEnabled -and $Mode -eq 'Dark')
        }

        if ($Persist) {
            try {
                if (-not (Test-Path -Path $themeRegistryPath)) {
                    New-Item -Path $themeRegistryPath -Force | Out-Null
                }
                Set-ItemProperty -Path $themeRegistryPath -Name Theme -Value $Mode -Type String
            }
            catch {
                Write-Host "Unable to save theme preference: $_"
            }
        }
    }
    finally {
        $form.ResumeLayout($true)
        $form.Refresh()
    }
}


$script:selectedInterface = $null
$script:adapterRecords = @()
$script:vmSwitchCache = $null
$script:emptyAdapterLabel = $null
$script:suppressAdapterFilterEvent = $false
$script:selectedAdapterHasIPv4 = $false
$script:selectedAdapterCanConfigure = $true
$script:dhcpServer = $null
$script:dhcpConfiguration = $null
$script:dhcpFirewallRuleName = $null
$script:dhcpStatusRetryTimer = $null
$script:dhcpStatusRetryInterface = $null
$ButtonGroup = ($btnSetLinkLocal, $btnSetDhcpLinkLocal, $btnDhcpServer, $btnCaptureIPtoSet, $btnCaptureIP)

function ButtonGroupEnable {
    param(
        [bool]$enable
    )
    $interfaceSelected = -not [string]::IsNullOrWhiteSpace($script:selectedInterface)
    $buttonsEnabled = $enable -and $interfaceSelected -and $runningAsAdmin -and $script:selectedAdapterCanConfigure

    $btnSetLinkLocal.Enabled = $buttonsEnabled
    $btnSetDhcpLinkLocal.Enabled = $buttonsEnabled
    $serverIsRunning = $null -ne $script:dhcpServer -and $script:dhcpServer.IsRunning
    $btnDhcpServer.Enabled = $serverIsRunning -or ($buttonsEnabled -and $script:selectedAdapterHasIPv4)
    $btnCaptureIP.Enabled = $buttonsEnabled
    $btnScanSubnet.Enabled = $enable -and $interfaceSelected -and $script:selectedAdapterHasIPv4
    Update-CapturedIPButton -EnableGroup:$enable
}

function Update-CapturedIPButton {
    param(
        [bool]$EnableGroup = $true
    )

    $enteredIP = $textBoxCapturedIP.Text.Trim()
    $hasIP = -not [string]::IsNullOrWhiteSpace($enteredIP)
    $hasValidIP = Test-ValidIPv4Address -Address $enteredIP
    $interfaceSelected = -not [string]::IsNullOrWhiteSpace($script:selectedInterface)

    if ($hasValidIP) {
        $btnCaptureIPtoSet.Text = "&Set static IPv4 to $enteredIP"
        $textBoxCapturedIP.ForeColor = $colorText
        $textBoxCapturedIP.AccessibleDescription = 'Valid IPv4 address.'
        if ($null -ne $validationErrors) {
            $validationErrors.SetError($textBoxCapturedIP, '')
        }
    }
    elseif ($hasIP) {
        $btnCaptureIPtoSet.Text = '&Enter a valid IPv4 address'
        $textBoxCapturedIP.ForeColor = $colorFailure
        $textBoxCapturedIP.AccessibleDescription = 'Invalid IPv4 address. Enter four numbers from 0 to 255 separated by periods.'
        if ($null -ne $validationErrors) {
            $validationErrors.SetError($textBoxCapturedIP, 'Enter a valid IPv4 address, for example 192.168.1.25.')
        }
    }
    else {
        $btnCaptureIPtoSet.Text = "&Enter an IP address to set static IPv4"
        $textBoxCapturedIP.ForeColor = $colorText
        $textBoxCapturedIP.AccessibleDescription = 'Enter four numbers from 0 to 255 separated by periods.'
        if ($null -ne $validationErrors) {
            $validationErrors.SetError($textBoxCapturedIP, '')
        }
    }

    $btnCaptureIPtoSet.Enabled = $EnableGroup -and $interfaceSelected -and $runningAsAdmin -and $hasValidIP
}

function Start-SubnetScan {
    $selectedInterface = $script:selectedInterface
    if ([string]::IsNullOrWhiteSpace($selectedInterface)) {
        return
    }

    $scanAddressInfo = Get-NetIPAddress -InterfaceAlias $selectedInterface -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.AddressState -ne 'Duplicate' } |
    Select-Object -First 1

    if (-not $scanAddressInfo) {
        [Windows.Forms.MessageBox]::Show('The selected adapter does not have an IPv4 subnet to scan.', 'Subnet Scan') | Out-Null
        return
    }

    $sourceAddress = $scanAddressInfo.IPAddress
    $prefixLength = [int]$scanAddressInfo.PrefixLength
    $interfaceIndex = [int]$scanAddressInfo.InterfaceIndex
    $localMacAddress = (Get-NetAdapter -InterfaceIndex $interfaceIndex -ErrorAction SilentlyContinue | Select-Object -First 1).MacAddress
    $subnetSize = [uint64][Math]::Pow(2, 32 - $prefixLength)
    $sourceValue = Convert-IPv4ToUInt32 -Address $sourceAddress
    $networkValue = [uint64]([Math]::Floor($sourceValue / $subnetSize) * $subnetSize)
    $networkAddress = Convert-UInt32ToIPv4 -Value $networkValue

    if ($prefixLength -le 30) {
        $firstHostValue = $networkValue + 1
        $lastHostValue = $networkValue + $subnetSize - 2
    }
    else {
        $firstHostValue = $networkValue
        $lastHostValue = $networkValue + $subnetSize - 1
    }
    $hostCount = [uint64]($lastHostValue - $firstHostValue + 1)

    $estimatedSeconds = [Math]::Ceiling($hostCount / 128.0) * 0.6
    $estimatedDuration = [TimeSpan]::FromSeconds([Math]::Min($estimatedSeconds, [TimeSpan]::MaxValue.TotalSeconds))
    $durationText = if ($estimatedDuration.TotalHours -ge 1) {
        '{0:N1} hours or more' -f $estimatedDuration.TotalHours
    }
    elseif ($estimatedDuration.TotalMinutes -ge 1) {
        '{0:N0} minutes or more' -f [Math]::Ceiling($estimatedDuration.TotalMinutes)
    }
    else {
        'under a minute in typical conditions'
    }

    $confirmationText = "Scan $networkAddress/$prefixLength on $selectedInterface?`r`n`r`nThe scan will ping $($hostCount.ToString('N0')) possible host addresses, then request hostnames only for addresses that reply."
    $confirmationIcon = [Windows.Forms.MessageBoxIcon]::Question
    if ($prefixLength -lt 24) {
        $confirmationText += "`r`n`r`nWarning: This subnet is larger than /24 and may take $durationText. Large scans can also generate substantial network traffic."
        $confirmationIcon = [Windows.Forms.MessageBoxIcon]::Warning
    }
    $confirmationText += "`r`n`r`nContinue?"

    $confirmation = [Windows.Forms.MessageBox]::Show(
        $confirmationText,
        'Confirm Subnet Scan',
        [Windows.Forms.MessageBoxButtons]::YesNo,
        $confirmationIcon,
        [Windows.Forms.MessageBoxDefaultButton]::Button2
    )
    if ($confirmation -ne [Windows.Forms.DialogResult]::Yes) {
        return
    }

    $scanForm = New-Object System.Windows.Forms.Form
    $scanForm.Text = "Subnet Scan - $networkAddress/$prefixLength"
    $scanForm.ClientSize = New-Object System.Drawing.Size(760, 560)
    $scanForm.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $scanForm.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $scanForm.MaximizeBox = $false
    $scanForm.MinimizeBox = $false
    $scanForm.BackColor = $colorBackground
    $scanForm.ForeColor = $colorText
    $scanForm.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $scanForm.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
    $scanForm.Icon = $form.Icon
    $scanForm.AccessibleName = 'Subnet scan report'

    $scanHeader = New-Object System.Windows.Forms.Panel
    $scanHeader.Dock = [System.Windows.Forms.DockStyle]::Top
    $scanHeader.Height = 76
    $scanHeader.BackColor = $colorSurface

    $scanTitle = New-Object System.Windows.Forms.Label
    $scanTitle.Location = New-Object System.Drawing.Point(18, 12)
    $scanTitle.Size = New-Object System.Drawing.Size(720, 26)
    $scanTitle.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 14)
    $scanTitle.ForeColor = $colorText
    $scanTitle.Text = "Scanning $networkAddress/$prefixLength"

    $scanSummary = New-Object System.Windows.Forms.Label
    $scanSummary.Location = New-Object System.Drawing.Point(20, 42)
    $scanSummary.Size = New-Object System.Drawing.Size(716, 20)
    $scanSummary.ForeColor = $colorMuted
    $scanSummary.Text = "$($hostCount.ToString('N0')) addresses via $selectedInterface"

    $scanHeader.Controls.Add($scanTitle)
    $scanHeader.Controls.Add($scanSummary)

    $scanStatus = New-Object System.Windows.Forms.Label
    $scanStatus.Location = New-Object System.Drawing.Point(18, 90)
    $scanStatus.Size = New-Object System.Drawing.Size(724, 22)
    $scanStatus.ForeColor = $colorText
    $scanStatus.Text = 'Starting ping scan...'
    $scanStatus.AccessibleName = 'Scan progress status'

    $liveSettingProperty = [System.Windows.Forms.Label].GetProperty('LiveSetting')
    if ($null -ne $liveSettingProperty) {
        $politeSetting = [System.Enum]::Parse($liveSettingProperty.PropertyType, 'Polite')
        $liveSettingProperty.SetValue($scanStatus, $politeSetting, $null)
    }

    $scanProgress = New-Object System.Windows.Forms.ProgressBar
    $scanProgress.Location = New-Object System.Drawing.Point(18, 116)
    $scanProgress.Size = New-Object System.Drawing.Size(724, 16)
    $scanProgress.Minimum = 0
    $scanProgress.Maximum = 100
    $scanProgress.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
    $scanProgress.AccessibleName = 'Subnet scan progress'

    $searchPanel = New-Object System.Windows.Forms.Panel
    $searchPanel.Location = New-Object System.Drawing.Point(18, 144)
    $searchPanel.Size = New-Object System.Drawing.Size(724, 34)
    $searchPanel.BackColor = $colorInput

    $searchIcon = New-Object System.Windows.Forms.Label
    $searchIcon.Location = New-Object System.Drawing.Point(9, 6)
    $searchIcon.Size = New-Object System.Drawing.Size(24, 22)
    $searchIcon.Font = New-Object System.Drawing.Font('Segoe MDL2 Assets', 11)
    $searchIcon.ForeColor = $colorMuted
    $searchIcon.Text = ([char]0xE721).ToString()
    $searchIcon.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter

    $textScanSearch = New-Object System.Windows.Forms.TextBox
    $textScanSearch.Location = New-Object System.Drawing.Point(39, 7)
    $textScanSearch.Size = New-Object System.Drawing.Size(638, 22)
    $textScanSearch.BackColor = $colorInput
    $textScanSearch.ForeColor = $colorText
    $textScanSearch.BorderStyle = [System.Windows.Forms.BorderStyle]::None
    $textScanSearch.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $textScanSearch.Enabled = $false
    $textScanSearch.AccessibleName = 'Filter scan results by hostname or MAC address'

    $searchHint = New-Object System.Windows.Forms.Label
    $searchHint.Location = New-Object System.Drawing.Point(40, 7)
    $searchHint.Size = New-Object System.Drawing.Size(400, 22)
    $searchHint.BackColor = $colorInput
    $searchHint.ForeColor = $colorMuted
    $searchHint.Text = 'Filter by hostname or MAC address'
    $searchHint.Cursor = [System.Windows.Forms.Cursors]::IBeam
    $searchHint.Add_Click({ $textScanSearch.Focus() })

    $btnClearSearch = New-Object System.Windows.Forms.Button
    $btnClearSearch.Location = New-Object System.Drawing.Point(686, 3)
    $btnClearSearch.Size = New-Object System.Drawing.Size(32, 28)
    $btnClearSearch.Text = ([char]0x2715).ToString()
    $btnClearSearch.Visible = $false
    $btnClearSearch.AccessibleName = 'Clear scan result filter'
    Set-ButtonStyle -Button $btnClearSearch
    $btnClearSearch.Add_Click({
            $textScanSearch.Clear()
            $textScanSearch.Focus()
        })

    $searchPanel.Controls.Add($searchIcon)
    $searchPanel.Controls.Add($textScanSearch)
    $searchPanel.Controls.Add($searchHint)
    $searchPanel.Controls.Add($btnClearSearch)

    $reportList = New-Object System.Windows.Forms.ListView
    $reportList.Location = New-Object System.Drawing.Point(18, 188)
    $reportList.Size = New-Object System.Drawing.Size(724, 312)
    $reportList.BackColor = $colorInput
    $reportList.ForeColor = $colorText
    $reportList.BorderStyle = [System.Windows.Forms.BorderStyle]::None
    $reportList.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $reportList.View = [System.Windows.Forms.View]::Details
    $reportList.FullRowSelect = $true
    $reportList.GridLines = $true
    $reportList.HideSelection = $false
    $reportList.ShowItemToolTips = $true
    $reportList.Columns.Add('IP Address', 150) | Out-Null
    $reportList.Columns.Add('Hostname', 368) | Out-Null
    $reportList.Columns.Add('MAC Address', 180) | Out-Null
    $reportList.AccessibleName = 'IP address, hostname, and MAC address report'

    $btnCopyReport = New-Object System.Windows.Forms.Button
    $btnCopyReport.Location = New-Object System.Drawing.Point(350, 514)
    $btnCopyReport.Size = New-Object System.Drawing.Size(120, 34)
    $btnCopyReport.Text = '&Copy report'
    $btnCopyReport.Enabled = $false
    Set-ButtonStyle -Button $btnCopyReport
    $btnCopyReport.Add_Click({
            if ($scanState.Results.Count -gt 0) {
                $textReport = New-Object System.Text.StringBuilder
                [void]$textReport.AppendLine("IP Address`tHostname`tMAC Address")
                foreach ($result in $scanState.Results) {
                    [void]$textReport.AppendLine("$($result.IPAddress)`t$($result.Hostname)`t$($result.MacAddress)")
                }
                [Windows.Forms.Clipboard]::SetText($textReport.ToString())
            }
        })

    $btnExportCsv = New-Object System.Windows.Forms.Button
    $btnExportCsv.Location = New-Object System.Drawing.Point(486, 514)
    $btnExportCsv.Size = New-Object System.Drawing.Size(120, 34)
    $btnExportCsv.Text = '&Export CSV'
    $btnExportCsv.Enabled = $false
    Set-ButtonStyle -Button $btnExportCsv
    $btnExportCsv.AccessibleDescription = 'Save all scan results with complete, untruncated hostnames to a CSV file.'
    $btnExportCsv.Add_Click({
            $saveDialog = New-Object System.Windows.Forms.SaveFileDialog
            $saveDialog.Title = 'Export Subnet Scan'
            $saveDialog.Filter = 'CSV files (*.csv)|*.csv|All files (*.*)|*.*'
            $saveDialog.DefaultExt = 'csv'
            $saveDialog.AddExtension = $true
            $saveDialog.FileName = "subnet-scan-$($networkAddress.Replace('.', '-'))-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
            if ($saveDialog.ShowDialog($scanForm) -eq [Windows.Forms.DialogResult]::OK) {
                try {
                    $scanState.Results |
                    Select-Object @{ Name = 'IP Address'; Expression = { $_.IPAddress } }, Hostname, @{ Name = 'MAC Address'; Expression = { $_.MacAddress } } |
                    Export-Csv -LiteralPath $saveDialog.FileName -NoTypeInformation -Encoding UTF8
                }
                catch {
                    [Windows.Forms.MessageBox]::Show("Unable to export the report: $($_.Exception.Message)", 'CSV Export Error', [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Error) | Out-Null
                }
            }
            $saveDialog.Dispose()
        })

    $btnScanBack = New-Object System.Windows.Forms.Button
    $btnScanBack.Location = New-Object System.Drawing.Point(622, 514)
    $btnScanBack.Size = New-Object System.Drawing.Size(120, 34)
    $btnScanBack.Text = '&Cancel'
    Set-ButtonStyle -Button $btnScanBack -BackColor $colorAccent -HoverColor $colorAccentHover

    $scanForm.Controls.Add($scanHeader)
    $scanForm.Controls.Add($scanStatus)
    $scanForm.Controls.Add($scanProgress)
    $scanForm.Controls.Add($searchPanel)
    $scanForm.Controls.Add($reportList)
    $scanForm.Controls.Add($btnCopyReport)
    $scanForm.Controls.Add($btnExportCsv)
    $scanForm.Controls.Add($btnScanBack)
    $scanForm.CancelButton = $btnScanBack

    $scanState = [hashtable]::Synchronized(@{
            Progress        = 0
            Status          = 'Starting ping scan...'
            ActiveCount     = 0
            Complete        = $false
            Finalized       = $false
            CancelRequested = $false
            Cancelled       = $false
            Error           = $null
            Results         = @()
        })

    $scanViewState = @{
        SortColumn = 0
        Ascending  = $true
    }

    $refreshScanResults = {
        $query = $textScanSearch.Text.Trim()
        $filteredResults = if ([string]::IsNullOrWhiteSpace($query)) {
            @($scanState.Results)
        }
        else {
            @($scanState.Results | Where-Object {
                    ([string]$_.Hostname).IndexOf($query, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                    ([string]$_.MacAddress).IndexOf($query, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
                })
        }

        $sortExpression = switch ($scanViewState.SortColumn) {
            0 { { Convert-IPv4ToUInt32 -Address $_.IPAddress } }
            1 { { [string]$_.Hostname } }
            2 { { [string]$_.MacAddress } }
        }
        $sortedResults = if ($scanViewState.Ascending) {
            @($filteredResults | Sort-Object -Property $sortExpression)
        }
        else {
            @($filteredResults | Sort-Object -Property $sortExpression -Descending)
        }

        $directionIndicator = if ($scanViewState.Ascending) { [char]0x25B2 } else { [char]0x25BC }
        $reportList.Columns[0].Text = 'IP Address' + $(if ($scanViewState.SortColumn -eq 0) { " $directionIndicator" } else { '' })
        $reportList.Columns[1].Text = 'Hostname' + $(if ($scanViewState.SortColumn -eq 1) { " $directionIndicator" } else { '' })
        $reportList.Columns[2].Text = 'MAC Address' + $(if ($scanViewState.SortColumn -eq 2) { " $directionIndicator" } else { '' })

        $reportList.BeginUpdate()
        try {
            $reportList.Items.Clear()
            if ($scanState.Results.Count -eq 0) {
                $emptyItem = New-Object System.Windows.Forms.ListViewItem('No hosts replied to ping.')
                $emptyItem.SubItems.Add('') | Out-Null
                $emptyItem.SubItems.Add('') | Out-Null
                $reportList.Items.Add($emptyItem) | Out-Null
            }
            elseif ($sortedResults.Count -eq 0) {
                $emptyItem = New-Object System.Windows.Forms.ListViewItem('No matching hosts.')
                $emptyItem.SubItems.Add('') | Out-Null
                $emptyItem.SubItems.Add('') | Out-Null
                $reportList.Items.Add($emptyItem) | Out-Null
            }
            else {
                foreach ($result in $sortedResults) {
                    $fullHostname = [string]$result.Hostname
                    $displayHostname = if ($fullHostname.Length -gt 44) {
                        $fullHostname.Substring(0, 41) + '...'
                    }
                    else {
                        $fullHostname
                    }

                    $resultItem = New-Object System.Windows.Forms.ListViewItem($result.IPAddress)
                    $resultItem.SubItems.Add($displayHostname) | Out-Null
                    $resultItem.SubItems.Add($result.MacAddress) | Out-Null
                    $resultItem.ToolTipText = $fullHostname
                    $reportList.Items.Add($resultItem) | Out-Null
                }
            }
        }
        finally {
            $reportList.EndUpdate()
        }

        if ($scanState.Finalized -and -not $scanState.Error -and -not $scanState.Cancelled) {
            $scanStatus.Text = if ([string]::IsNullOrWhiteSpace($query)) {
                "Complete: $($scanState.Results.Count) active hosts found"
            }
            else {
                "Showing $($sortedResults.Count) of $($scanState.Results.Count) active hosts"
            }
        }
    }

    $reportList.Add_ColumnClick({
            if ($scanViewState.SortColumn -eq $_.Column) {
                $scanViewState.Ascending = -not $scanViewState.Ascending
            }
            else {
                $scanViewState.SortColumn = $_.Column
                $scanViewState.Ascending = $true
            }
            & $refreshScanResults
        })
    $textScanSearch.Add_TextChanged({
            $hasSearchText = -not [string]::IsNullOrWhiteSpace($textScanSearch.Text)
            $searchHint.Visible = -not $hasSearchText
            $btnClearSearch.Visible = $hasSearchText
            if ($scanState.Finalized) {
                & $refreshScanResults
            }
        })

    $workerScript = {
        param(
            [uint64]$FirstHost,
            [uint64]$LastHost,
            [uint64]$TotalHosts,
            [int]$InterfaceIndex,
            [string]$LocalAddress,
            [string]$LocalMacAddress,
            [hashtable]$State
        )

        function Convert-ScanValueToIPv4([uint64]$Value) {
            return '{0}.{1}.{2}.{3}' -f ([Math]::Floor($Value / 16777216) % 256), ([Math]::Floor($Value / 65536) % 256), ([Math]::Floor($Value / 256) % 256), ($Value % 256)
        }

        try {
            $activeAddresses = New-Object System.Collections.Generic.List[string]
            $processed = [uint64]0
            $batchSize = 128
            $currentValue = $FirstHost

            while ($currentValue -le $LastHost) {
                if ($State.CancelRequested) { throw [System.OperationCanceledException]::new() }

                $pingJobs = New-Object System.Collections.Generic.List[object]
                $batchAttempts = 0
                for ($index = 0; $index -lt $batchSize -and $currentValue -le $LastHost; $index++) {
                    $address = Convert-ScanValueToIPv4 $currentValue
                    $ping = New-Object System.Net.NetworkInformation.Ping
                    try {
                        $task = $ping.SendPingAsync($address, 450)
                        $pingJobs.Add([PSCustomObject]@{ Address = $address; Ping = $ping; Task = $task })
                    }
                    catch {
                        $ping.Dispose()
                    }
                    $currentValue++
                    $batchAttempts++
                }

                $tasks = [System.Threading.Tasks.Task[]]@($pingJobs | ForEach-Object { $_.Task })
                if ($tasks.Count -gt 0) {
                    try { [System.Threading.Tasks.Task]::WaitAll($tasks) } catch { }
                }
                foreach ($job in $pingJobs) {
                    try {
                        if ($job.Task.Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion -and
                            $job.Task.Result.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                            $activeAddresses.Add($job.Address)
                        }
                    }
                    finally {
                        $job.Ping.Dispose()
                    }
                }

                $processed += $batchAttempts
                $State.ActiveCount = $activeAddresses.Count
                $State.Progress = [Math]::Min(70, [int](($processed / [double]$TotalHosts) * 70))
                $State.Status = "Ping scan: $($processed.ToString('N0')) of $($TotalHosts.ToString('N0')) checked; $($activeAddresses.Count) active"
            }

            $State.Status = "Gathering MAC addresses for $($activeAddresses.Count) active hosts..."
            $neighborMacAddresses = @{}
            try {
                $neighbors = Get-NetNeighbor -InterfaceIndex $InterfaceIndex -AddressFamily IPv4 -ErrorAction Stop
                foreach ($neighbor in $neighbors) {
                    if (-not [string]::IsNullOrWhiteSpace($neighbor.LinkLayerAddress) -and
                        $neighbor.LinkLayerAddress -ne '00-00-00-00-00-00') {
                        $neighborMacAddresses[$neighbor.IPAddress] = $neighbor.LinkLayerAddress
                    }
                }
            }
            catch {
                # Some virtual adapters do not expose a neighbor table. Results remain useful without MAC data.
            }

            $State.Status = "Resolving hostnames for $($activeAddresses.Count) active hosts..."
            $results = New-Object System.Collections.Generic.List[object]
            $dnsBatchSize = 32
            for ($offset = 0; $offset -lt $activeAddresses.Count; $offset += $dnsBatchSize) {
                if ($State.CancelRequested) { throw [System.OperationCanceledException]::new() }

                $dnsJobs = New-Object System.Collections.Generic.List[object]
                $batchEnd = [Math]::Min($offset + $dnsBatchSize, $activeAddresses.Count)
                for ($dnsIndex = $offset; $dnsIndex -lt $batchEnd; $dnsIndex++) {
                    $address = $activeAddresses[$dnsIndex]
                    $macAddress = '(unavailable)'
                    if ($address -eq $LocalAddress -and -not [string]::IsNullOrWhiteSpace($LocalMacAddress)) {
                        $macAddress = $LocalMacAddress
                    }
                    elseif ($neighborMacAddresses.ContainsKey($address)) {
                        $macAddress = $neighborMacAddresses[$address]
                    }
                    try {
                        $task = [System.Net.Dns]::GetHostEntryAsync($address)
                        $dnsJobs.Add([PSCustomObject]@{ Address = $address; MacAddress = $macAddress; Task = $task })
                    }
                    catch {
                        $results.Add([PSCustomObject]@{ IPAddress = $address; Hostname = '(no PTR record)'; MacAddress = $macAddress })
                    }
                }

                $dnsTasks = [System.Threading.Tasks.Task[]]@($dnsJobs | ForEach-Object { $_.Task })
                if ($dnsTasks.Count -gt 0) {
                    try { [System.Threading.Tasks.Task]::WaitAll($dnsTasks, 5000) | Out-Null } catch { }
                }
                foreach ($job in $dnsJobs) {
                    $hostname = '(no PTR record)'
                    if ($job.Task.Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion -and $job.Task.Result.HostName) {
                        $hostname = $job.Task.Result.HostName
                    }
                    $results.Add([PSCustomObject]@{ IPAddress = $job.Address; Hostname = $hostname; MacAddress = $job.MacAddress })
                }

                $resolvedCount = [Math]::Min($batchEnd, $activeAddresses.Count)
                $State.Progress = if ($activeAddresses.Count -eq 0) { 100 } else { 70 + [int](($resolvedCount / [double]$activeAddresses.Count) * 30) }
                $State.Status = "Hostname lookup: $resolvedCount of $($activeAddresses.Count) complete"
            }

            $State.Results = $results.ToArray()
            $State.Progress = 100
            $State.Status = "Complete: $($results.Count) active hosts found"
            $State.Complete = $true
        }
        catch [System.OperationCanceledException] {
            $State.Cancelled = $true
            $State.Status = 'Scan cancelled.'
            $State.Complete = $true
        }
        catch {
            $State.Error = "$($_.Exception.Message) (scan worker line $($_.InvocationInfo.ScriptLineNumber))"
            $State.Status = 'The scan could not be completed.'
            $State.Complete = $true
        }
    }

    $scanPowerShell = [PowerShell]::Create()
    $scanPowerShell.AddScript($workerScript).AddArgument($firstHostValue).AddArgument($lastHostValue).AddArgument($hostCount).AddArgument($interfaceIndex).AddArgument($sourceAddress).AddArgument($localMacAddress).AddArgument($scanState) | Out-Null
    $scanAsyncResult = $scanPowerShell.BeginInvoke()

    $scanTimer = New-Object System.Windows.Forms.Timer
    $scanTimer.Interval = 150
    $scanTimer.Add_Tick({
            $scanProgress.Value = [Math]::Max(0, [Math]::Min(100, [int]$scanState.Progress))
            $scanStatus.Text = $scanState.Status

            if ($scanState.Complete -and -not $scanState.Finalized) {
                $scanState.Finalized = $true
                $scanTimer.Stop()
                try { $scanPowerShell.EndInvoke($scanAsyncResult) | Out-Null } catch { }
                $scanPowerShell.Dispose()

                if ($scanState.Cancelled) {
                    $cancelledItem = New-Object System.Windows.Forms.ListViewItem('Scan cancelled')
                    $cancelledItem.SubItems.Add('The subnet scan was cancelled.') | Out-Null
                    $cancelledItem.SubItems.Add('') | Out-Null
                    $reportList.Items.Add($cancelledItem) | Out-Null
                }
                elseif ($scanState.Error) {
                    $errorItem = New-Object System.Windows.Forms.ListViewItem('Scan error')
                    $errorItem.SubItems.Add($scanState.Error) | Out-Null
                    $errorItem.SubItems.Add('') | Out-Null
                    $errorItem.ToolTipText = $scanState.Error
                    $reportList.Items.Add($errorItem) | Out-Null
                }
                else {
                    & $refreshScanResults
                    $textScanSearch.Enabled = $true
                    if ($scanState.Results.Count -gt 0) {
                        $btnCopyReport.Enabled = $true
                        $btnExportCsv.Enabled = $true
                    }
                }

                $btnScanBack.Text = '&Back'
                $btnScanBack.Enabled = $true
            }
        })

    $btnScanBack.Add_Click({
            if (-not $scanState.Complete) {
                $cancelConfirmation = [Windows.Forms.MessageBox]::Show(
                    'Cancel the subnet scan?',
                    'Cancel Scan',
                    [Windows.Forms.MessageBoxButtons]::YesNo,
                    [Windows.Forms.MessageBoxIcon]::Question,
                    [Windows.Forms.MessageBoxDefaultButton]::Button2
                )
                if ($cancelConfirmation -eq [Windows.Forms.DialogResult]::Yes) {
                    $scanState.CancelRequested = $true
                    $scanStatus.Text = 'Cancelling scan...'
                    $btnScanBack.Enabled = $false
                }
            }
            else {
                $scanForm.Close()
            }
        })

    $scanForm.Add_FormClosing({
            if (-not $scanState.Complete) {
                $_.Cancel = $true
                $btnScanBack.PerformClick()
            }
        })
    $scanForm.Add_Shown({
            [NICChangerNativeV2]::SetDarkTitleBar($scanForm.Handle, -not [Windows.Forms.SystemInformation]::HighContrast -and $script:themeMode -eq 'Dark')
            $scanTimer.Start()
        })
    $scanForm.Add_FormClosed({
            $scanTimer.Stop()
            $scanTimer.Dispose()
        })

    [void]$scanForm.ShowDialog($form)
    $scanForm.Dispose()
}

function Get-DhcpAdapterSettings {
    param([string]$InterfaceAlias)

    if ([string]::IsNullOrWhiteSpace($InterfaceAlias)) {
        throw 'Select a network adapter first.'
    }

    $adapter = Get-NetAdapter -InterfaceAlias $InterfaceAlias -ErrorAction Stop
    if ($adapter.Status -ne 'Up') {
        throw "The selected adapter is $($adapter.Status). Connect it before enabling the DHCP server."
    }

    $addresses = @(Get-NetIPAddress -InterfaceAlias $InterfaceAlias -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object {
                $_.PrefixLength -le 30 -and $_.IPAddress -ne '0.0.0.0' -and
                $_.IPAddress -notlike '127.*' -and $_.AddressState -ne 'Duplicate'
            } |
            Sort-Object @{ Expression = { if ($_.IPAddress -like '169.254.*') { 1 } else { 0 } } },
            @{ Expression = { if ($_.PrefixOrigin -eq 'Manual') { 0 } else { 1 } } })

    if ($addresses.Count -eq 0) {
        throw 'The selected adapter needs an IPv4 address with a /30 or larger subnet before NIC Changer can inspect it for DHCP service.'
    }

    $address = $addresses[0]
    return [PSCustomObject]@{
        AdapterAlias  = $InterfaceAlias
        InterfaceIndex = [int]$adapter.ifIndex
        ServerAddress = $address.IPAddress
        PrefixLength  = [int]$address.PrefixLength
        SubnetMask    = Convert-PrefixToSubnetMask -PrefixLength ([int]$address.PrefixLength)
        PrefixOrigin  = $address.PrefixOrigin.ToString()
        IsStatic      = $address.PrefixOrigin -eq 'Manual'
    }
}

function Get-DhcpPoolDefaults {
    param([PSCustomObject]$AdapterSettings)

    $serverValue = Convert-IPv4ToUInt32 -Address $AdapterSettings.ServerAddress
    $blockSize = [uint64][Math]::Pow(2, 32 - $AdapterSettings.PrefixLength)
    $network = [uint64]([Math]::Floor($serverValue / $blockSize) * $blockSize)
    $broadcast = $network + $blockSize - 1
    $segments = @()

    if ($serverValue -gt ($network + 1)) {
        $segments += [PSCustomObject]@{ Start = $network + 1; End = $serverValue - 1 }
    }
    if ($serverValue -lt ($broadcast - 1)) {
        $segments += [PSCustomObject]@{ Start = $serverValue + 1; End = $broadcast - 1 }
    }
    if ($segments.Count -eq 0) {
        throw 'This subnet has no usable client addresses outside the server address.'
    }

    $preferredStart = $network + 100
    $segment = $segments |
        Sort-Object @{ Expression = {
                    if ($preferredStart -ge $_.Start -and $preferredStart -le $_.End) { 0 } else { 1 }
                } }, @{ Expression = { -($_.End - $_.Start + 1) } } |
        Select-Object -First 1

    $segmentCapacity = [uint64]($segment.End - $segment.Start + 1)
    $poolSize = [int][Math]::Min(20, $segmentCapacity)
    $poolStart = if ($preferredStart -ge $segment.Start -and
        ($preferredStart + $poolSize - 1) -le $segment.End) {
        $preferredStart
    }
    else {
        $segment.Start
    }

    return [PSCustomObject]@{
        PoolStart   = Convert-UInt32ToIPv4 -Value $poolStart
        PoolSize    = $poolSize
        MaxPoolSize = [int][Math]::Min(250, $segmentCapacity)
        Network     = $network
        Broadcast   = $broadcast
    }
}

function ConvertTo-DhcpIPv4List {
    param(
        [string]$Text,
        [string]$FieldName
    )

    $addresses = @()
    if (-not [string]::IsNullOrWhiteSpace($Text)) {
        foreach ($value in @($Text -split '[,;\s]+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
            if (-not (Test-ValidIPv4Address -Address $value)) {
                throw "$FieldName contains an invalid IPv4 address: $value"
            }
            if ($value -notin $addresses) {
                $addresses += $value
            }
        }
    }
    return @($addresses)
}

function Test-DhcpConfiguration {
    param(
        [PSCustomObject]$AdapterSettings,
        [string]$PoolStart,
        [int]$PoolSize,
        [int]$LeaseMinutes,
        [string]$Router,
        [string]$DnsText,
        [string]$NtpText,
        [string]$DomainName
    )

    if (-not (Test-ValidIPv4Address -Address $PoolStart)) {
        throw 'Enter a valid IPv4 address for the pool start.'
    }
    if ($PoolSize -lt 1 -or $PoolSize -gt 250) {
        throw 'Pool size must be between 1 and 250 addresses.'
    }
    if ($LeaseMinutes -lt 1 -or $LeaseMinutes -gt 10080) {
        throw 'Lease time must be between 1 minute and 7 days.'
    }

    $serverValue = Convert-IPv4ToUInt32 -Address $AdapterSettings.ServerAddress
    $blockSize = [uint64][Math]::Pow(2, 32 - $AdapterSettings.PrefixLength)
    $network = [uint64]([Math]::Floor($serverValue / $blockSize) * $blockSize)
    $broadcast = $network + $blockSize - 1
    $poolStartValue = Convert-IPv4ToUInt32 -Address $PoolStart
    $poolEndValue = $poolStartValue + [uint64]$PoolSize - 1

    if ($poolStartValue -le $network -or $poolEndValue -ge $broadcast -or $poolEndValue -lt $poolStartValue) {
        throw "The complete pool must be inside $((Convert-UInt32ToIPv4 -Value $network))/$($AdapterSettings.PrefixLength) and cannot include its network or broadcast address."
    }
    if ($serverValue -ge $poolStartValue -and $serverValue -le $poolEndValue) {
        throw "The pool includes this computer's server address, $($AdapterSettings.ServerAddress)."
    }

    $routerValue = $Router.Trim()
    if (-not [string]::IsNullOrWhiteSpace($routerValue) -and -not (Test-ValidIPv4Address -Address $routerValue)) {
        throw 'Enter a valid IPv4 router address or leave the router field blank.'
    }
    if (-not [string]::IsNullOrWhiteSpace($routerValue)) {
        $routerNumber = Convert-IPv4ToUInt32 -Address $routerValue
        if ($routerNumber -le $network -or $routerNumber -ge $broadcast) {
            throw 'The router address must be on the selected adapter subnet.'
        }
    }

    $dnsAddresses = @(ConvertTo-DhcpIPv4List -Text $DnsText -FieldName 'DNS servers')
    $ntpAddresses = @(ConvertTo-DhcpIPv4List -Text $NtpText -FieldName 'NTP servers')
    if ($dnsAddresses.Count -gt 31 -or $ntpAddresses.Count -gt 31) {
        throw 'DNS and NTP lists can each contain at most 31 IPv4 addresses.'
    }

    $reservedAddresses = @($routerValue) + $dnsAddresses + $ntpAddresses |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -Unique
    foreach ($reservedAddress in $reservedAddresses) {
        $reservedValue = Convert-IPv4ToUInt32 -Address $reservedAddress
        if ($reservedValue -ge $poolStartValue -and $reservedValue -le $poolEndValue) {
            throw "The pool includes configured infrastructure address $reservedAddress. Move it outside the pool."
        }
    }

    $domain = $DomainName.Trim()
    if ($domain.Length -gt 253 -or ($domain.Length -gt 0 -and $domain -notmatch '^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$')) {
        throw 'The domain name may contain letters, numbers, periods, and hyphens, and cannot begin or end with punctuation.'
    }

    $poolAddresses = for ($value = $poolStartValue; $value -le $poolEndValue; $value++) {
        Convert-UInt32ToIPv4 -Value $value
    }

    return [PSCustomObject]@{
        AdapterAlias  = $AdapterSettings.AdapterAlias
        InterfaceIndex = $AdapterSettings.InterfaceIndex
        ServerAddress = $AdapterSettings.ServerAddress
        PrefixLength  = $AdapterSettings.PrefixLength
        SubnetMask    = $AdapterSettings.SubnetMask
        PoolStart     = $PoolStart
        PoolEnd       = Convert-UInt32ToIPv4 -Value $poolEndValue
        PoolSize      = $PoolSize
        PoolAddresses = @($poolAddresses)
        LeaseMinutes  = $LeaseMinutes
        Router        = $routerValue
        DnsServers    = @($dnsAddresses)
        NtpServers    = @($ntpAddresses)
        DomainName    = $domain
    }
}

function Test-DhcpPoolAvailability {
    param(
        [string[]]$Addresses,
        [string]$SourceAddress,
        [System.Windows.Forms.Label]$StatusLabel
    )

    $activeAddresses = New-Object System.Collections.Generic.List[string]
    $pending = New-Object System.Collections.Generic.List[object]
    $nextAddressIndex = 0
    $checked = 0
    $batchSize = 12

    try {
        while ($nextAddressIndex -lt $Addresses.Count -or $pending.Count -gt 0) {
            while ($nextAddressIndex -lt $Addresses.Count -and $pending.Count -lt $batchSize) {
                $address = $Addresses[$nextAddressIndex]
                $processInfo = New-Object System.Diagnostics.ProcessStartInfo
                $processInfo.FileName = 'ping.exe'
                $processInfo.Arguments = "-S $SourceAddress -n 1 -w 700 $address"
                $processInfo.UseShellExecute = $false
                $processInfo.CreateNoWindow = $true
                $processInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
                $process = New-Object System.Diagnostics.Process
                $process.StartInfo = $processInfo
                if (-not $process.Start()) {
                    throw "Unable to start the ping safety check for $address."
                }
                $pending.Add([PSCustomObject]@{ Address = $address; Process = $process })
                $nextAddressIndex++
            }

            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 20
            for ($index = $pending.Count - 1; $index -ge 0; $index--) {
                $item = $pending[$index]
                if ($item.Process.HasExited) {
                    if ($item.Process.ExitCode -eq 0) {
                        $activeAddresses.Add($item.Address)
                    }
                    $item.Process.Dispose()
                    $pending.RemoveAt($index)
                    $checked++
                    if ($null -ne $StatusLabel -and -not $StatusLabel.IsDisposed) {
                        $StatusLabel.Text = "Ping safety check: $checked of $($Addresses.Count) addresses checked"
                    }
                }
            }
        }
    }
    finally {
        foreach ($item in $pending.ToArray()) {
            try {
                if (-not $item.Process.HasExited) {
                    $item.Process.Kill()
                    $item.Process.WaitForExit(250) | Out-Null
                }
            }
            catch {
                # The short-lived ping process may have exited between checks.
            }
            finally {
                $item.Process.Dispose()
            }
        }
    }

    return $activeAddresses.ToArray()
}

function Get-WindowsDhcpLeaseInfo {
    param([string]$InterfaceAlias)

    try {
        $adapter = Get-NetAdapter -InterfaceAlias $InterfaceAlias -ErrorAction Stop
        $adapterGuid = if ($null -ne $adapter.InterfaceGuid) { $adapter.InterfaceGuid.ToString().Trim('{}') } else { '' }
        $configurations = @(Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration `
                -Filter 'IPEnabled = TRUE' -ErrorAction Stop)

        $configuration = $configurations |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace($adapterGuid) -and
                -not [string]::IsNullOrWhiteSpace($_.SettingID) -and
                $_.SettingID.ToString().Trim('{}') -eq $adapterGuid
            } |
            Select-Object -First 1
        if ($null -eq $configuration) {
            $configuration = $configurations |
                Where-Object { [uint32]$_.InterfaceIndex -eq [uint32]$adapter.ifIndex } |
                Select-Object -First 1
        }

        if ($null -eq $configuration) {
            return [PSCustomObject]@{
                QuerySucceeded = $true
                ConfigurationFound = $false
                DhcpEnabled    = $false
                HasActiveLease = $false
                ServerAddress  = $null
                LeaseObtained  = $null
                LeaseExpires   = $null
                Error          = $null
            }
        }

        $serverAddress = $configuration.DHCPServer
        $serverIsValid = Test-ValidIPv4Address -Address $serverAddress
        if ($serverAddress -in @('0.0.0.0', '255.255.255.255')) {
            $serverIsValid = $false
        }

        $dhcpAddresses = @(Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 `
                -PrefixOrigin Dhcp -ErrorAction SilentlyContinue |
                Where-Object { $_.AddressState -ne 'Duplicate' })

        $leaseExpires = $configuration.DHCPLeaseExpires
        $leaseObtained = $configuration.DHCPLeaseObtained
        $expirationIsKnown = $null -ne $leaseExpires -and $leaseExpires -is [DateTime] -and
            $leaseExpires -gt [DateTime]'1970-01-01'
        $leaseIsCurrent = -not $expirationIsKnown -or $leaseExpires -gt (Get-Date)
        $hasActiveLease = [bool]$configuration.DHCPEnabled -and $serverIsValid -and
            $dhcpAddresses.Count -gt 0 -and $leaseIsCurrent

        return [PSCustomObject]@{
            QuerySucceeded = $true
            ConfigurationFound = $true
            DhcpEnabled    = [bool]$configuration.DHCPEnabled
            HasActiveLease = $hasActiveLease
            ServerAddress  = if ($serverIsValid) { $serverAddress } else { $null }
            LeaseObtained  = $leaseObtained
            LeaseExpires   = $leaseExpires
            Error          = $null
        }
    }
    catch {
        return [PSCustomObject]@{
            QuerySucceeded = $false
            ConfigurationFound = $false
            DhcpEnabled    = $false
            HasActiveLease = $false
            ServerAddress  = $null
            LeaseObtained  = $null
            LeaseExpires   = $null
            Error          = $_.Exception.Message
        }
    }
}

function Test-ExistingDhcpServer {
    param(
        [PSCustomObject]$AdapterSettings,
        [int]$TimeoutMilliseconds = 3000
    )

    $windowsLease = Get-WindowsDhcpLeaseInfo -InterfaceAlias $AdapterSettings.AdapterAlias
    if ($windowsLease.HasActiveLease) {
        return [PSCustomObject]@{
            ServerFound     = $true
            ServerIdentifier = $windowsLease.ServerAddress
            SourceAddress   = $windowsLease.ServerAddress
            Error           = $null
            DetectionMethod = 'Windows active lease'
            LeaseExpires    = $windowsLease.LeaseExpires
        }
    }

    $serverValue = Convert-IPv4ToUInt32 -Address $AdapterSettings.ServerAddress
    $blockSize = [uint64][Math]::Pow(2, 32 - $AdapterSettings.PrefixLength)
    $network = [uint64]([Math]::Floor($serverValue / $blockSize) * $blockSize)
    $broadcastAddress = Convert-UInt32ToIPv4 -Value ($network + $blockSize - 1)
    $probe = $null
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $probe = [NICChangerDhcpProbe]::Probe($AdapterSettings.InterfaceIndex, $broadcastAddress, $TimeoutMilliseconds)
        if ([string]::IsNullOrWhiteSpace($probe.Error)) {
            break
        }
        if ($attempt -lt 3) {
            # Windows can retain DHCP client port 68 briefly while an adapter is
            # transitioning from automatic to static addressing.
            Start-Sleep -Milliseconds (250 * $attempt)
        }
    }
    return [PSCustomObject]@{
        ServerFound     = $probe.ServerFound
        ServerIdentifier = $probe.ServerIdentifier
        SourceAddress   = $probe.SourceAddress
        Error           = $probe.Error
        DetectionMethod = 'Active discovery'
        LeaseExpires    = $null
    }
}

function Start-DhcpStatusRetry {
    if ($null -ne $script:dhcpStatusRetryTimer) {
        $script:dhcpStatusRetryTimer.Stop()
        $script:dhcpStatusRetryTimer.Dispose()
    }

    $script:dhcpStatusRetryInterface = $script:selectedInterface
    $script:dhcpStatusRetryTimer = New-Object System.Windows.Forms.Timer
    $script:dhcpStatusRetryTimer.Interval = 1500
    $script:dhcpStatusRetryTimer.Add_Tick({
            $script:dhcpStatusRetryTimer.Stop()
            $script:dhcpStatusRetryTimer.Dispose()
            $script:dhcpStatusRetryTimer = $null
            if ($script:selectedInterface -eq $script:dhcpStatusRetryInterface -and
                $null -ne $form -and -not $form.IsDisposed) {
                Update-DhcpStatusCard -IsRetry
            }
        })
    $script:dhcpStatusRetryTimer.Start()
}

function Update-DhcpStatusCard {
    param([switch]$IsRetry)

    if ($null -eq $dhcpStatusCard -or $dhcpStatusCard.Panel.IsDisposed) {
        return
    }

    $selectedInterface = $script:selectedInterface
    $localServerIsSelected = $null -ne $script:dhcpServer -and $script:dhcpServer.IsRunning -and
        $null -ne $script:dhcpConfiguration -and
        $script:dhcpConfiguration.AdapterAlias -eq $selectedInterface

    if ($localServerIsSelected) {
        Set-StatusCard -Card $dhcpStatusCard -Text 'This tool' -State Success
        $details = "NIC Changer is serving DHCP on $selectedInterface."
        $dhcpStatusCard.Value.AccessibleDescription = $details
        if ($null -ne $toolTip) { $toolTip.SetToolTip($dhcpStatusCard.Panel, $details) }
        return
    }

    if ([string]::IsNullOrWhiteSpace($selectedInterface)) {
        Set-StatusCard -Card $dhcpStatusCard -Text 'Not checked' -State Neutral
        return
    }
    if (-not $script:selectedAdapterHasIPv4) {
        Set-StatusCard -Card $dhcpStatusCard -Text 'No IPv4' -State Neutral
        return
    }

    Set-StatusCard -Card $dhcpStatusCard -Text 'Checking...' -State Pending
    $dhcpStatusCard.Panel.Refresh()
    $shouldRetry = $false
    try {
        $adapterSettings = Get-DhcpAdapterSettings -InterfaceAlias $selectedInterface
        $probe = Test-ExistingDhcpServer -AdapterSettings $adapterSettings -TimeoutMilliseconds 1500
        if (-not [string]::IsNullOrWhiteSpace($probe.Error)) {
            Set-StatusCard -Card $dhcpStatusCard -Text 'Unable to check' -State Failure
            $details = "DHCP discovery failed: $($probe.Error)"
            $shouldRetry = $true
        }
        elseif ($probe.ServerFound) {
            Set-StatusCard -Card $dhcpStatusCard -Text 'External server' -State Success
            $details = "An external DHCP server was detected at $($probe.ServerIdentifier) using $($probe.DetectionMethod)."
            if ($null -ne $probe.LeaseExpires) {
                $details += " The Windows lease expires $($probe.LeaseExpires.ToString('g'))."
            }
        }
        else {
            Set-StatusCard -Card $dhcpStatusCard -Text 'No server' -State Neutral
            $details = 'No DHCP server answered the discovery probe on the selected adapter.'
        }
    }
    catch {
        Set-StatusCard -Card $dhcpStatusCard -Text 'Unable to check' -State Failure
        $details = "DHCP discovery failed: $($_.Exception.Message)"
        $shouldRetry = $true
    }

    $dhcpStatusCard.Value.AccessibleDescription = $details
    if ($null -ne $toolTip) { $toolTip.SetToolTip($dhcpStatusCard.Panel, $details) }
    if ($shouldRetry -and -not $IsRetry) {
        Start-DhcpStatusRetry
    }
}

function Add-DhcpFirewallRule {
    param([string]$InterfaceAlias)

    $ruleName = "NICChanger-Temporary-DHCP-$PID-$([Guid]::NewGuid().ToString('N'))"
    New-NetFirewallRule -Name $ruleName -DisplayName 'NIC Changer temporary DHCP server' `
        -Description "Temporary inbound DHCP rule created by NIC Changer process $PID. Remove when the server stops." `
        -Group 'NIC Changer Temporary DHCP' -Direction Inbound -Action Allow -Enabled True `
        -Protocol UDP -LocalPort 67 -InterfaceAlias $InterfaceAlias -Profile Any `
        -PolicyStore ActiveStore -ErrorAction Stop | Out-Null
    $script:dhcpFirewallRuleName = $ruleName
}

function Remove-DhcpFirewallRule {
    if (-not [string]::IsNullOrWhiteSpace($script:dhcpFirewallRuleName)) {
        try {
            Remove-NetFirewallRule -Name $script:dhcpFirewallRuleName -PolicyStore ActiveStore -ErrorAction Stop
        }
        catch {
            Write-Host "Unable to remove temporary DHCP firewall rule: $_"
        }
        finally {
            $script:dhcpFirewallRuleName = $null
        }
    }
}

function Stop-NICChangerDhcpServer {
    if ($null -ne $script:dhcpServer) {
        try {
            $script:dhcpServer.Stop()
        }
        catch {
            Write-Host "Unable to stop DHCP server cleanly: $_"
        }
    }
    Remove-DhcpFirewallRule
    if ($null -ne $btnDhcpServer -and -not $btnDhcpServer.IsDisposed) {
        Update-DhcpServerButton
        ButtonGroupEnable($true)
    }
}

function Update-DhcpServerButton {
    if ($null -eq $btnDhcpServer -or $btnDhcpServer.IsDisposed) {
        return
    }

    $serverIsRunning = $null -ne $script:dhcpServer -and $script:dhcpServer.IsRunning
    if ($serverIsRunning) {
        $btnDhcpServer.Text = '&Manage DHCP Server (running)'
        $btnDhcpServer.AccessibleName = 'Manage running DHCP Server'
        $btnDhcpServer.AccessibleDescription = 'Opens the running temporary DHCP server to view leases or stop it.'
        Set-ButtonStyle -Button $btnDhcpServer -BackColor $colorAccent -HoverColor $colorAccentHover
    }
    else {
        $btnDhcpServer.Text = '&Enable DHCP Server'
        $btnDhcpServer.AccessibleName = 'Enable DHCP Server'
        $btnDhcpServer.AccessibleDescription = 'Checks for another DHCP server and address conflicts before opening a temporary DHCP server on the selected adapter.'
        Set-ButtonStyle -Button $btnDhcpServer
    }
}

function New-DhcpDialogLabel {
    param(
        [System.Windows.Forms.Control]$Parent,
        [string]$Text,
        [int]$X,
        [int]$Y,
        [int]$Width
    )

    $label = New-Object System.Windows.Forms.Label
    $label.Location = New-Object System.Drawing.Point($X, $Y)
    $label.Size = New-Object System.Drawing.Size($Width, 18)
    $label.ForeColor = $colorMuted
    $label.Text = $Text
    $Parent.Controls.Add($label)
    return $label
}

function New-DhcpDialogTextBox {
    param(
        [System.Windows.Forms.Control]$Parent,
        [string]$Text,
        [int]$X,
        [int]$Y,
        [int]$Width,
        [switch]$ReadOnly
    )

    $textBox = New-Object System.Windows.Forms.TextBox
    $textBox.Location = New-Object System.Drawing.Point($X, $Y)
    $textBox.Size = New-Object System.Drawing.Size($Width, 27)
    $textBox.BackColor = $colorInput
    $textBox.ForeColor = $colorText
    $textBox.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $textBox.Font = New-Object System.Drawing.Font('Consolas', 9)
    $textBox.Text = $Text
    $textBox.ReadOnly = $ReadOnly
    $Parent.Controls.Add($textBox)
    return $textBox
}

function Show-DhcpServerDialog {
    $serverIsRunning = $null -ne $script:dhcpServer -and $script:dhcpServer.IsRunning
    if (-not $serverIsRunning -and -not [string]::IsNullOrWhiteSpace($script:dhcpFirewallRuleName)) {
        Remove-DhcpFirewallRule
        Update-DhcpServerButton
    }
    $adapterSettings = $null
    $defaults = $null

    if ($serverIsRunning) {
        $adapterSettings = $script:dhcpConfiguration
    }
    else {
        try {
            $adapterSettings = Get-DhcpAdapterSettings -InterfaceAlias $script:selectedInterface
            $defaults = Get-DhcpPoolDefaults -AdapterSettings $adapterSettings
        }
        catch {
            [Windows.Forms.MessageBox]::Show(
                $_.Exception.Message,
                'DHCP Server Cannot Start',
                [Windows.Forms.MessageBoxButtons]::OK,
                [Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
            return
        }

        $previousNotice = $configNoticeLabel.Text
        $configNoticeLabel.Text = 'Checking for an existing DHCP server...'
        $form.UseWaitCursor = $true
        [System.Windows.Forms.Application]::DoEvents()
        try {
            $probe = Test-ExistingDhcpServer -AdapterSettings $adapterSettings
        }
        finally {
            $form.UseWaitCursor = $false
            $configNoticeLabel.Text = $previousNotice
        }

        if (-not [string]::IsNullOrWhiteSpace($probe.Error)) {
            Set-StatusCard -Card $dhcpStatusCard -Text 'Unable to check' -State Failure
            [Windows.Forms.MessageBox]::Show(
                "NIC Changer could not verify that this network is free of DHCP servers:`r`n`r`n$($probe.Error)`r`n`r`nNo DHCP server was enabled because the safety check must succeed first.",
                'DHCP Safety Check Failed',
                [Windows.Forms.MessageBoxButtons]::OK,
                [Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
            return
        }
        if ($probe.ServerFound) {
            Set-StatusCard -Card $dhcpStatusCard -Text 'External server' -State Success
            $dhcpStatusCard.Value.AccessibleDescription = "An external DHCP server was detected at $($probe.ServerIdentifier) using $($probe.DetectionMethod)."
            [Windows.Forms.MessageBox]::Show(
                "An existing DHCP server was detected on $($adapterSettings.AdapterAlias).`r`n`r`nServer: $($probe.ServerIdentifier)`r`nDetected by: $($probe.DetectionMethod)`r`n`r`nNIC Changer did not enable another server because competing DHCP servers can give devices conflicting network settings.",
                'Existing DHCP Server Detected',
                [Windows.Forms.MessageBoxButtons]::OK,
                [Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
            return
        }
        Set-StatusCard -Card $dhcpStatusCard -Text 'No server' -State Neutral
        if (-not $adapterSettings.IsStatic) {
            [Windows.Forms.MessageBox]::Show(
                'No DHCP server answered the safety probe, but the selected adapter does not have a static IPv4 address. Assign a static address to this adapter before starting the temporary DHCP server so its server address cannot change.',
                'Static IPv4 Address Required',
                [Windows.Forms.MessageBoxButtons]::OK,
                [Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
            return
        }
    }

    if ($null -eq $defaults) {
        $defaults = Get-DhcpPoolDefaults -AdapterSettings $adapterSettings
    }

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = 'Temporary DHCP Server'
    $dialog.ClientSize = New-Object System.Drawing.Size(780, 650)
    $dialog.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $dialog.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.BackColor = $colorBackground
    $dialog.ForeColor = $colorText
    $dialog.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $dialog.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
    if ($null -ne $script:appIcon) { $dialog.Icon = $script:appIcon }

    $heading = New-Object System.Windows.Forms.Label
    $heading.Location = New-Object System.Drawing.Point(20, 16)
    $heading.Size = New-Object System.Drawing.Size(740, 28)
    $heading.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 15)
    $heading.ForeColor = $colorText
    $heading.Text = 'Temporary DHCP Server'
    $dialog.Controls.Add($heading)

    $description = New-Object System.Windows.Forms.Label
    $description.Location = New-Object System.Drawing.Point(20, 48)
    $description.Size = New-Object System.Drawing.Size(740, 38)
    $description.ForeColor = $colorMuted
    $description.Text = 'For direct, temporary device setup only. NIC Changer checks for another DHCP server and pings every pool address before listening.'
    $dialog.Controls.Add($description)

    New-DhcpDialogLabel -Parent $dialog -Text 'ADAPTER / SERVER ADDRESS' -X 20 -Y 92 -Width 350 | Out-Null
    New-DhcpDialogLabel -Parent $dialog -Text 'SUBNET MASK' -X 392 -Y 92 -Width 170 | Out-Null
    $textServer = New-DhcpDialogTextBox -Parent $dialog -Text "$($adapterSettings.AdapterAlias)  |  $($adapterSettings.ServerAddress)/$($adapterSettings.PrefixLength)" -X 20 -Y 112 -Width 350 -ReadOnly
    $textMask = New-DhcpDialogTextBox -Parent $dialog -Text $adapterSettings.SubnetMask -X 392 -Y 112 -Width 170 -ReadOnly

    New-DhcpDialogLabel -Parent $dialog -Text 'POOL START' -X 20 -Y 154 -Width 200 | Out-Null
    New-DhcpDialogLabel -Parent $dialog -Text 'POOL SIZE' -X 242 -Y 154 -Width 120 | Out-Null
    New-DhcpDialogLabel -Parent $dialog -Text 'LEASE (MINUTES)' -X 384 -Y 154 -Width 160 | Out-Null
    $initialPoolStart = if ($serverIsRunning) { $script:dhcpConfiguration.PoolStart } else { $defaults.PoolStart }
    $initialPoolSize = if ($serverIsRunning) { $script:dhcpConfiguration.PoolSize } else { $defaults.PoolSize }
    $initialLeaseMinutes = if ($serverIsRunning) { $script:dhcpConfiguration.LeaseMinutes } else { 120 }
    $textPoolStart = New-DhcpDialogTextBox -Parent $dialog -Text $initialPoolStart -X 20 -Y 174 -Width 200

    $numberPoolSize = New-Object System.Windows.Forms.NumericUpDown
    $numberPoolSize.Location = New-Object System.Drawing.Point(242, 174)
    $numberPoolSize.Size = New-Object System.Drawing.Size(120, 27)
    $numberPoolSize.Minimum = 1
    $numberPoolSize.Maximum = 250
    $numberPoolSize.Value = $initialPoolSize
    $numberPoolSize.BackColor = $colorInput
    $numberPoolSize.ForeColor = $colorText
    $dialog.Controls.Add($numberPoolSize)

    $numberLease = New-Object System.Windows.Forms.NumericUpDown
    $numberLease.Location = New-Object System.Drawing.Point(384, 174)
    $numberLease.Size = New-Object System.Drawing.Size(160, 27)
    $numberLease.Minimum = 1
    $numberLease.Maximum = 10080
    $numberLease.Value = $initialLeaseMinutes
    $numberLease.BackColor = $colorInput
    $numberLease.ForeColor = $colorText
    $dialog.Controls.Add($numberLease)

    New-DhcpDialogLabel -Parent $dialog -Text 'ROUTER / GATEWAY (OPTIONAL)' -X 20 -Y 216 -Width 220 | Out-Null
    New-DhcpDialogLabel -Parent $dialog -Text 'DNS SERVERS (COMMA-SEPARATED)' -X 278 -Y 216 -Width 230 | Out-Null
    New-DhcpDialogLabel -Parent $dialog -Text 'NTP SERVERS (COMMA-SEPARATED)' -X 520 -Y 216 -Width 240 | Out-Null
    $initialRouter = if ($serverIsRunning) { $script:dhcpConfiguration.Router } else { '' }
    $initialDns = if ($serverIsRunning) { $script:dhcpConfiguration.DnsServers -join ', ' } else { '' }
    $initialNtp = if ($serverIsRunning) { $script:dhcpConfiguration.NtpServers -join ', ' } else { '' }
    $textRouter = New-DhcpDialogTextBox -Parent $dialog -Text $initialRouter -X 20 -Y 236 -Width 236
    $textDns = New-DhcpDialogTextBox -Parent $dialog -Text $initialDns -X 278 -Y 236 -Width 220
    $textNtp = New-DhcpDialogTextBox -Parent $dialog -Text $initialNtp -X 520 -Y 236 -Width 240

    New-DhcpDialogLabel -Parent $dialog -Text 'DOMAIN NAME (OPTIONAL)' -X 20 -Y 278 -Width 230 | Out-Null
    $initialDomain = if ($serverIsRunning) { $script:dhcpConfiguration.DomainName } else { '' }
    $textDomain = New-DhcpDialogTextBox -Parent $dialog -Text $initialDomain -X 20 -Y 298 -Width 236

    $statusLabel = New-Object System.Windows.Forms.Label
    $statusLabel.Location = New-Object System.Drawing.Point(278, 290)
    $statusLabel.Size = New-Object System.Drawing.Size(482, 40)
    $statusLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $statusLabel.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9)
    $statusLabel.ForeColor = if ($serverIsRunning) { $colorSuccess } else { $colorMuted }
    $statusLabel.Text = if ($serverIsRunning) {
        "Running on $($script:dhcpConfiguration.AdapterAlias); pool $($script:dhcpConfiguration.PoolStart) - $($script:dhcpConfiguration.PoolEnd)"
    }
    else {
        'Ready. Enabling will repeat the DHCP-server check, then ping the complete pool.'
    }
    $dialog.Controls.Add($statusLabel)

    $btnServerAction = New-Object System.Windows.Forms.Button
    $btnServerAction.Location = New-Object System.Drawing.Point(20, 345)
    $btnServerAction.Size = New-Object System.Drawing.Size(236, 38)
    $btnServerAction.Text = if ($serverIsRunning) { '&Stop DHCP Server' } else { '&Enable DHCP Server' }
    Set-ButtonStyle -Button $btnServerAction -BackColor $(if ($serverIsRunning) { $colorFailure } else { $colorAccent }) -HoverColor $(if ($serverIsRunning) { $colorFailure } else { $colorAccentHover })
    $dialog.Controls.Add($btnServerAction)

    $btnCloseDhcp = New-Object System.Windows.Forms.Button
    $btnCloseDhcp.Location = New-Object System.Drawing.Point(624, 345)
    $btnCloseDhcp.Size = New-Object System.Drawing.Size(136, 38)
    $btnCloseDhcp.Text = '&Close'
    Set-ButtonStyle -Button $btnCloseDhcp
    $btnCloseDhcp.Add_Click({ $dialog.Close() })
    $dialog.Controls.Add($btnCloseDhcp)
    $dialog.CancelButton = $btnCloseDhcp

    $leaseHeading = New-Object System.Windows.Forms.Label
    $leaseHeading.Location = New-Object System.Drawing.Point(20, 398)
    $leaseHeading.Size = New-Object System.Drawing.Size(740, 24)
    $leaseHeading.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 11)
    $leaseHeading.ForeColor = $colorText
    $leaseHeading.Text = 'Devices issued an address'
    $dialog.Controls.Add($leaseHeading)

    $leaseList = New-Object System.Windows.Forms.ListView
    $leaseList.Location = New-Object System.Drawing.Point(20, 426)
    $leaseList.Size = New-Object System.Drawing.Size(740, 198)
    $leaseList.View = [System.Windows.Forms.View]::Details
    $leaseList.FullRowSelect = $true
    $leaseList.GridLines = $true
    $leaseList.BackColor = $colorInput
    $leaseList.ForeColor = $colorText
    $leaseList.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $leaseList.Columns.Add('IP address', 120) | Out-Null
    $leaseList.Columns.Add('MAC address', 145) | Out-Null
    $leaseList.Columns.Add('Host name', 135) | Out-Null
    $leaseList.Columns.Add('Status', 75) | Out-Null
    $leaseList.Columns.Add('Leased at', 120) | Out-Null
    $leaseList.Columns.Add('Expires at', 120) | Out-Null
    $leaseList.AccessibleName = 'Devices issued addresses by the temporary DHCP server'
    $dialog.Controls.Add($leaseList)

    $dialog.AccessibleName = 'Temporary DHCP Server'
    $dialog.AccessibleDescription = 'Configure, enable, monitor, and stop a temporary DHCP server on the selected adapter.'
    $textServer.AccessibleName = 'DHCP server adapter and address'
    $textMask.AccessibleName = 'DHCP subnet mask'
    $textPoolStart.AccessibleName = 'DHCP pool start address'
    $numberPoolSize.AccessibleName = 'DHCP pool size'
    $numberLease.AccessibleName = 'DHCP lease duration in minutes'
    $textRouter.AccessibleName = 'Optional router or gateway address'
    $textDns.AccessibleName = 'DNS server addresses'
    $textNtp.AccessibleName = 'NTP server addresses'
    $textDomain.AccessibleName = 'Optional domain name'
    $statusLabel.AccessibleName = 'DHCP server status'
    $btnServerAction.AccessibleName = if ($serverIsRunning) { 'Stop DHCP Server' } else { 'Enable DHCP Server' }
    $btnCloseDhcp.AccessibleName = 'Close DHCP server window'
    $dialogLiveSettingProperty = [System.Windows.Forms.Label].GetProperty('LiveSetting')
    if ($null -ne $dialogLiveSettingProperty) {
        $dialogPoliteSetting = [System.Enum]::Parse($dialogLiveSettingProperty.PropertyType, 'Polite')
        $dialogLiveSettingProperty.SetValue($statusLabel, $dialogPoliteSetting, $null)
    }

    $configurationControls = @($textPoolStart, $numberPoolSize, $numberLease, $textRouter, $textDns, $textNtp, $textDomain)
    foreach ($control in $configurationControls) { $control.Enabled = -not $serverIsRunning }

    $refreshLeases = {
        if ($null -eq $script:dhcpServer) { return }
        $leases = @($script:dhcpServer.GetLeases())
        $leaseList.BeginUpdate()
        try {
            $leaseList.Items.Clear()
            foreach ($lease in $leases) {
                $item = New-Object System.Windows.Forms.ListViewItem($lease.IPAddress)
                $item.SubItems.Add($lease.MacAddress) | Out-Null
                $item.SubItems.Add($(if ([string]::IsNullOrWhiteSpace($lease.HostName)) { ([char]0x2014).ToString() } else { $lease.HostName })) | Out-Null
                $item.SubItems.Add($lease.Status) | Out-Null
                $item.SubItems.Add($lease.LeasedAt.ToString('yyyy-MM-dd HH:mm:ss')) | Out-Null
                $item.SubItems.Add($lease.ExpiresAt.ToString('yyyy-MM-dd HH:mm:ss')) | Out-Null
                $leaseList.Items.Add($item) | Out-Null
            }
            if ($leases.Count -eq 0) {
                $emptyItem = New-Object System.Windows.Forms.ListViewItem('No devices have received an address yet.')
                $emptyItem.ForeColor = $colorMuted
                $leaseList.Items.Add($emptyItem) | Out-Null
            }
        }
        finally {
            $leaseList.EndUpdate()
        }
    }

    $btnServerAction.Add_Click({
            if ($null -ne $script:dhcpServer -and $script:dhcpServer.IsRunning) {
                Stop-NICChangerDhcpServer
                Update-DhcpStatusCard
                $statusLabel.Text = 'DHCP server stopped. Lease history remains visible for this session.'
                $statusLabel.ForeColor = $colorMuted
                $btnServerAction.Text = '&Enable DHCP Server'
                $btnServerAction.AccessibleName = 'Enable DHCP Server'
                Set-ButtonStyle -Button $btnServerAction -BackColor $colorAccent -HoverColor $colorAccentHover
                foreach ($control in $configurationControls) { $control.Enabled = $true }
                return
            }

            try {
                $currentAdapterSettings = Get-DhcpAdapterSettings -InterfaceAlias $adapterSettings.AdapterAlias
                if (-not $currentAdapterSettings.IsStatic) {
                    throw 'The selected adapter no longer has a static IPv4 address.'
                }
                if ($currentAdapterSettings.ServerAddress -ne $adapterSettings.ServerAddress -or
                    $currentAdapterSettings.PrefixLength -ne $adapterSettings.PrefixLength) {
                    throw 'The adapter address or subnet changed while this window was open. Close and reopen the DHCP server window to recalculate a safe pool.'
                }

                $configuration = Test-DhcpConfiguration -AdapterSettings $currentAdapterSettings `
                    -PoolStart $textPoolStart.Text.Trim() -PoolSize ([int]$numberPoolSize.Value) `
                    -LeaseMinutes ([int]$numberLease.Value) -Router $textRouter.Text `
                    -DnsText $textDns.Text -NtpText $textNtp.Text -DomainName $textDomain.Text

                $btnServerAction.Enabled = $false
                $btnCloseDhcp.Enabled = $false
                $dialog.ControlBox = $false
                foreach ($control in $configurationControls) { $control.Enabled = $false }
                $dialog.UseWaitCursor = $true
                $statusLabel.ForeColor = $colorWarning
                $statusLabel.Text = 'Checking again for an existing DHCP server...'
                [System.Windows.Forms.Application]::DoEvents()

                $probe = Test-ExistingDhcpServer -AdapterSettings $currentAdapterSettings
                if (-not [string]::IsNullOrWhiteSpace($probe.Error)) {
                    Set-StatusCard -Card $dhcpStatusCard -Text 'Unable to check' -State Failure
                    throw "The DHCP safety check could not complete: $($probe.Error)"
                }
                if ($probe.ServerFound) {
                    Set-StatusCard -Card $dhcpStatusCard -Text 'External server' -State Success
                    $dhcpStatusCard.Value.AccessibleDescription = "An external DHCP server was detected at $($probe.ServerIdentifier) using $($probe.DetectionMethod)."
                    [Windows.Forms.MessageBox]::Show(
                        "An existing DHCP server was detected before startup.`r`n`r`nServer: $($probe.ServerIdentifier)`r`nDetected by: $($probe.DetectionMethod)`r`n`r`nNIC Changer stopped the operation to avoid competing DHCP servers and conflicting client settings.",
                        'Existing DHCP Server Detected',
                        [Windows.Forms.MessageBoxButtons]::OK,
                        [Windows.Forms.MessageBoxIcon]::Warning
                    ) | Out-Null
                    $statusLabel.Text = 'Not enabled: another DHCP server answered the safety probe.'
                    $statusLabel.ForeColor = $colorFailure
                    return
                }
                Set-StatusCard -Card $dhcpStatusCard -Text 'No server' -State Neutral

                $statusLabel.Text = "Pinging all $($configuration.PoolSize) addresses in the proposed pool..."
                [System.Windows.Forms.Application]::DoEvents()
                $addressesInUse = @(Test-DhcpPoolAvailability -Addresses $configuration.PoolAddresses `
                        -SourceAddress $configuration.ServerAddress -StatusLabel $statusLabel)
                if ($addressesInUse.Count -gt 0) {
                    $preview = ($addressesInUse | Select-Object -First 12) -join ', '
                    if ($addressesInUse.Count -gt 12) { $preview += ", and $($addressesInUse.Count - 12) more" }
                    [Windows.Forms.MessageBox]::Show(
                        "The following proposed lease addresses replied to ping:`r`n`r`n$preview`r`n`r`nNo DHCP server was enabled. Move the pool to an unused range or remove the conflicting devices, then try again.",
                        'DHCP Pool Addresses Already In Use',
                        [Windows.Forms.MessageBoxButtons]::OK,
                        [Windows.Forms.MessageBoxIcon]::Warning
                    ) | Out-Null
                    $statusLabel.Text = "Not enabled: $($addressesInUse.Count) pool address(es) replied to ping."
                    $statusLabel.ForeColor = $colorFailure
                    return
                }

                $statusLabel.Text = 'Opening the temporary firewall rule and starting DHCP...'
                [System.Windows.Forms.Application]::DoEvents()
                Add-DhcpFirewallRule -InterfaceAlias $configuration.AdapterAlias
                $candidateServer = $null
                try {
                    $candidateServer = New-Object NICChangerDhcpServer(
                        $configuration.ServerAddress,
                        $configuration.InterfaceIndex,
                        $configuration.PoolStart,
                        $configuration.PoolSize,
                        $configuration.SubnetMask,
                        $configuration.Router,
                        [string[]]$configuration.DnsServers,
                        [string[]]$configuration.NtpServers,
                        $configuration.DomainName,
                        $configuration.LeaseMinutes
                    )
                    $candidateServer.Start()
                }
                catch {
                    if ($null -ne $candidateServer) { $candidateServer.Dispose() }
                    Remove-DhcpFirewallRule
                    throw
                }

                $script:dhcpServer = $candidateServer
                $script:dhcpConfiguration = $configuration
                Update-DhcpServerButton
                Update-DhcpStatusCard
                $statusLabel.Text = "Running on $($configuration.AdapterAlias); pool $($configuration.PoolStart) - $($configuration.PoolEnd)"
                $statusLabel.ForeColor = $colorSuccess
                $btnServerAction.Text = '&Stop DHCP Server'
                $btnServerAction.AccessibleName = 'Stop DHCP Server'
                Set-ButtonStyle -Button $btnServerAction -BackColor $colorFailure -HoverColor $colorFailure
                $btnDhcpServer.Enabled = $true
                & $refreshLeases
            }
            catch {
                $statusLabel.Text = "DHCP server not enabled: $($_.Exception.Message)"
                $statusLabel.ForeColor = $colorFailure
                [Windows.Forms.MessageBox]::Show(
                    "NIC Changer did not enable the DHCP server:`r`n`r`n$($_.Exception.Message)",
                    'DHCP Server Cannot Start',
                    [Windows.Forms.MessageBoxButtons]::OK,
                    [Windows.Forms.MessageBoxIcon]::Warning
                ) | Out-Null
            }
            finally {
                $dialog.UseWaitCursor = $false
                $dialog.ControlBox = $true
                $btnCloseDhcp.Enabled = $true
                $btnServerAction.Enabled = $true
                $stillRunning = $null -ne $script:dhcpServer -and $script:dhcpServer.IsRunning
                if (-not $stillRunning) {
                    foreach ($control in $configurationControls) { $control.Enabled = $true }
                }
            }
        })

    $leaseTimer = New-Object System.Windows.Forms.Timer
    $leaseTimer.Interval = 1000
    $leaseTimer.Add_Tick({
            if ($null -ne $script:dhcpServer) {
                & $refreshLeases
                if (-not $script:dhcpServer.IsRunning -and
                    -not [string]::IsNullOrWhiteSpace($script:dhcpServer.LastError) -and
                    -not [string]::IsNullOrWhiteSpace($script:dhcpFirewallRuleName)) {
                    Remove-DhcpFirewallRule
                    $statusLabel.Text = "DHCP server stopped unexpectedly: $($script:dhcpServer.LastError)"
                    $statusLabel.ForeColor = $colorFailure
                    $btnServerAction.Text = '&Enable DHCP Server'
                    $btnServerAction.AccessibleName = 'Enable DHCP Server'
                    Set-ButtonStyle -Button $btnServerAction -BackColor $colorAccent -HoverColor $colorAccentHover
                    foreach ($control in $configurationControls) { $control.Enabled = $true }
                    Update-DhcpServerButton
                    Update-DhcpStatusCard
                    ButtonGroupEnable($true)
                }
            }
        })

    $dialog.Add_Shown({
            [NICChangerNativeV2]::SetDarkTitleBar($dialog.Handle, -not [Windows.Forms.SystemInformation]::HighContrast -and $script:themeMode -eq 'Dark')
            & $refreshLeases
            $leaseTimer.Start()
        })
    $dialog.Add_FormClosed({
            $leaseTimer.Stop()
            $leaseTimer.Dispose()
        })

    [void]$dialog.ShowDialog($form)
    $dialog.Dispose()
}


# Function to set the DHCP and Link Local IP for the selected interface
function Set-DHCP-LinkLocal-IP {
    $selectedInterface = $script:selectedInterface

    if ($selectedInterface -ne $null) {
        # Write-Host "Setting DHCP IP for $($selectedInterface)"

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

function Update-AdapterButtonStyles {
    foreach ($control in $adapterListPanel.Controls) {
        if ($control -is [System.Windows.Forms.Button]) {
            if ($control.Tag -eq $script:selectedInterface) {
                Set-ButtonStyle -Button $control -BackColor $colorAccent -HoverColor $colorAccentHover
            }
            else {
                Set-ButtonStyle -Button $control
            }
        }
        elseif ($control -is [System.Windows.Forms.Label]) {
            $control.ForeColor = $colorMuted
        }
    }
}

function Select-NetworkInterface {
    param([string]$InterfaceAlias)

    if ([string]::IsNullOrWhiteSpace($InterfaceAlias)) {
        return
    }

    $selectionChanged = $script:selectedInterface -ne $InterfaceAlias
    $script:selectedInterface = $InterfaceAlias
    Update-AdapterButtonStyles

    if ($selectionChanged) {
        Get-SelectedInterfaceInfo
    }
}

function Update-AdapterFilter {
    $preferredSelection = $script:selectedInterface
    $vmSwitches = @()
    $inspectHyperVSwitches = $checkHideUplinks.Checked

    if ($inspectHyperVSwitches) {
        if ($null -eq $script:vmSwitchCache) {
            $previousWaitCursor = $form.UseWaitCursor
            $previousAdapterHint = $adapterHint.Text
            $checkHideUplinks.Enabled = $false
            $adapterListPanel.Enabled = $false
            $checkHideUplinks.Text = 'Scanning Hyper-V...'
            $checkHideUplinks.AccessibleDescription = 'Please wait while Hyper-V switch uplinks are detected.'
            $adapterHeading.Text = 'Please wait...'
            $adapterHint.Text = 'Detecting Hyper-V switch uplinks.'
            $form.UseWaitCursor = $true
            $form.Refresh()
            [System.Windows.Forms.Application]::DoEvents()

            try {
                # An empty array is also cached so an unavailable or empty result is not retried.
                $script:vmSwitchCache = @()
                $getVMSwitchCommand = Get-Command -Name Get-VMSwitch -ErrorAction SilentlyContinue
                if ($getVMSwitchCommand) {
                    $script:vmSwitchCache = @(Get-VMSwitch -ErrorAction Stop)
                }
            }
            catch {
                Write-Host "Unable to inspect Hyper-V switches: $_"
            }
            finally {
                $checkHideUplinks.Text = '&Hide Hyper-V switch uplinks'
                $checkHideUplinks.AccessibleDescription = 'Filters physical adapters reserved as uplinks for external Hyper-V switches.'
                $adapterHint.Text = $previousAdapterHint
                $checkHideUplinks.Enabled = $true
                $adapterListPanel.Enabled = $true
                $form.UseWaitCursor = $previousWaitCursor
            }
        }

        $vmSwitches = @($script:vmSwitchCache)
    }

    foreach ($record in $script:adapterRecords) {
        if ($inspectHyperVSwitches) {
            if ($null -eq $record.HyperVContext) {
                $record.HyperVContext = Get-AdapterContext -InterfaceInfo $record.InterfaceInfo -VMSwitches $vmSwitches -InspectHyperVSwitches
            }
            $record.Context = $record.HyperVContext
        }
        else {
            $record.Context = $record.BasicContext
        }
    }

    Show-AdapterButtons -PreferredSelection $preferredSelection

    $selectedRecord = $script:adapterRecords | Where-Object { $_.Alias -eq $script:selectedInterface } | Select-Object -First 1
    if ($selectedRecord) {
        $script:selectedAdapterCanConfigure = $selectedRecord.Context.CanConfigure
        $lblAdapterTypeValue.Text = $selectedRecord.Context.DisplayText
        $configNoticeLabel.Text = $selectedRecord.Context.Notice
        ButtonGroupEnable($true)
    }
}

function Show-AdapterButtons {
    param([string]$PreferredSelection = $script:selectedInterface)

    $adapterListPanel.SuspendLayout()
    try {
        $visibleAdapters = @($script:adapterRecords | Where-Object {
                -not $checkHideUplinks.Checked -or -not $_.Context.IsSwitchUplink
            })
        $visibleAliases = @($visibleAdapters | ForEach-Object { $_.Alias })
        $adapterHeading.Text = "Network adapters ($($visibleAdapters.Count))"

        foreach ($record in $script:adapterRecords) {
            if ($null -eq $record.Button) {
                $adapterButton = New-Object System.Windows.Forms.Button
                $adapterButton.Size = New-Object System.Drawing.Size(212, 62)
                $adapterButton.Margin = New-Object System.Windows.Forms.Padding(3)
                $adapterButton.Padding = New-Object System.Windows.Forms.Padding(9, 4, 7, 4)
                $adapterButton.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
                $adapterButton.AutoEllipsis = $true
                $adapterButton.Tag = $record.Alias
                $adapterButton.Text = $record.Alias
                $adapterButton.AccessibleName = $record.Alias
                $adapterButton.Add_Click({ Select-NetworkInterface -InterfaceAlias $this.Tag })
                $record.Button = $adapterButton
                $adapterListPanel.Controls.Add($adapterButton)
            }

            $record.Button.AccessibleDescription = if ($record.Context.IsSwitchUplink) {
                'Physical adapter used by a Hyper-V external switch. Select for details; configure the host-facing vEthernet adapter instead.'
            }
            else {
                'Select this adapter to view status and configuration options.'
            }
            $record.Button.Visible = $record.Alias -in $visibleAliases
        }

        if ($null -eq $script:emptyAdapterLabel) {
            $script:emptyAdapterLabel = New-Object System.Windows.Forms.Label
            $script:emptyAdapterLabel.Size = New-Object System.Drawing.Size(210, 64)
            $script:emptyAdapterLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
            $script:emptyAdapterLabel.ForeColor = $colorMuted
            $adapterListPanel.Controls.Add($script:emptyAdapterLabel)
        }

        $script:emptyAdapterLabel.Visible = $visibleAdapters.Count -eq 0
        if ($visibleAdapters.Count -eq 0) {
            $script:emptyAdapterLabel.Text = if ($script:adapterRecords.Count -gt 0) { 'No adapters match the filter.' } else { 'No network adapters found.' }
            $script:emptyAdapterLabel.AccessibleName = $script:emptyAdapterLabel.Text
            $script:selectedInterface = $null
            ButtonGroupEnable($false)
        }
        else {
            $targetSelection = $PreferredSelection
            if ($targetSelection -notin @($visibleAdapters | ForEach-Object { $_.Alias })) {
                $targetSelection = $visibleAdapters[0].Alias
            }
            Select-NetworkInterface -InterfaceAlias $targetSelection
        }

        Update-AdapterButtonStyles
    }
    finally {
        $adapterListPanel.ResumeLayout($true)
    }
}

# Function to refresh network interfaces
function Get-NetworkInterface {
    $previousSelection = $script:selectedInterface
    $btnRefresh.Enabled = $false
    $btnRefresh.Text = 'Refreshing...'

    # Refresh always returns to the complete, unfiltered adapter list.
    $script:suppressAdapterFilterEvent = $true
    $checkHideUplinks.Checked = $false
    $script:suppressAdapterFilterEvent = $false

    try {
        $interfaces = Get-NetAdapter | Sort-Object -Property InterfaceAlias
        foreach ($control in @($adapterListPanel.Controls)) {
            $control.Dispose()
        }
        $adapterListPanel.Controls.Clear()
        $script:emptyAdapterLabel = $null
        $script:adapterRecords = @($interfaces | Where-Object { -not [string]::IsNullOrEmpty($_.InterfaceAlias) } | ForEach-Object {
                $basicContext = Get-AdapterContext -InterfaceInfo $_
                [PSCustomObject]@{
                    Alias         = $_.InterfaceAlias
                    Status        = $_.Status
                    InterfaceInfo = $_
                    BasicContext  = $basicContext
                    HyperVContext = $null
                    Context       = $basicContext
                    Button        = $null
                }
            })

        # Clear the active selection so a refresh also refreshes its details.
        $script:selectedInterface = $null
        Show-AdapterButtons -PreferredSelection $previousSelection
    }
    catch {
        Write-Host "Error retrieving network adapters: $_"
        Set-StatusCard -Card $adapterStatusCard -Text 'Unavailable' -State Failure
    }
    finally {
        $btnRefresh.Enabled = $true
        $btnRefresh.Text = ([char]0x21BB).ToString() + '  &Refresh adapters'
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

function Test-IPv4AddressInUse {
    param(
        [string]$Address,
        [string]$SourceAddress
    )

    if ([string]::IsNullOrWhiteSpace($SourceAddress)) {
        & ping.exe -n 1 -w 1000 $Address *> $null
    }
    else {
        & ping.exe -S $SourceAddress -n 1 -w 1000 $Address *> $null
    }

    return $LASTEXITCODE -eq 0
}


# Function to get selected interface info
function Get-SelectedInterfaceInfo {
    $selectedInterface = $script:selectedInterface

    if ($selectedInterface) {
        #Write-Host "Selected interface: $selectedInterface"
        $script:selectedAdapterHasIPv4 = $false
        ButtonGroupEnable($false)
        $form.UseWaitCursor = $true
        Set-StatusCard -Card $adapterStatusCard -Text 'Checking...' -State Pending
        Set-StatusCard -Card $internetStatusCard -Text 'Checking...' -State Pending
        Set-StatusCard -Card $dnsStatusCard -Text 'Checking...' -State Pending
        Set-StatusCard -Card $dhcpStatusCard -Text 'Checking...' -State Pending
        $lblAdapterTypeValue.Text = 'Detecting...'
        $lblMacAddressValue.Text = 'Loading...'
        $lblIPv4Value.Text = 'Loading...'
        $lblPrefixValue.Text = 'Loading...'
        $lblIPv6Value.Text = 'Loading...'
        $configNoticeLabel.Text = ''
        $form.Refresh()

        try {
            # Write-Host "Retrieving interface information"
            $interfaceInfo = Get-NetAdapter | Where-Object { $_.InterfaceAlias -eq $selectedInterface }

            if (-not $interfaceInfo) {
                throw "Interface not found"
            }

            $adapterRecord = $script:adapterRecords | Where-Object { $_.Alias -eq $selectedInterface } | Select-Object -First 1
            $adapterContext = if ($adapterRecord) {
                $adapterRecord.Context
            }
            else {
                Get-AdapterContext -InterfaceInfo $interfaceInfo
            }
            $script:selectedAdapterCanConfigure = $adapterContext.CanConfigure
            $lblAdapterTypeValue.Text = $adapterContext.DisplayText
            $lblMacAddressValue.Text = if ([string]::IsNullOrWhiteSpace($interfaceInfo.MacAddress)) { 'Not available' } else { $interfaceInfo.MacAddress }
            $configNoticeLabel.Text = $adapterContext.Notice

            if ($interfaceInfo.Status -eq 'Up') {
                Set-StatusCard -Card $adapterStatusCard -Text 'Up' -State Success
            }
            else {
                Set-StatusCard -Card $adapterStatusCard -Text $interfaceInfo.Status -State Failure
            }

            #Write-Host "Retrieving IPv4 addresses"
            $ipv4Info = @(Get-NetIPAddress -InterfaceAlias $selectedInterface -AddressFamily IPv4 -ErrorAction SilentlyContinue)
            $ipv4Addresses = @($ipv4Info | ForEach-Object { $_.IPAddress })
            $ipv4SubnetMask = @($ipv4Info | ForEach-Object { $_.PrefixLength })
            #Write-Host "Retrieving IPv6 addresses"
            $ipv6Addresses = @(Get-NetIPAddress -InterfaceAlias $selectedInterface -AddressFamily IPv6 -ErrorAction SilentlyContinue | ForEach-Object { $_.IPAddress })

            $lblIPv4Value.Text = if ($ipv4Addresses.Count -gt 0) { $ipv4Addresses -join ', ' } else { 'No IPv4 address' }
            $lblPrefixValue.Text = if ($ipv4SubnetMask.Count -gt 0) { $ipv4SubnetMask -join ', ' } else { ([char]0x2014).ToString() }
            $lblIPv6Value.Text = if ($ipv6Addresses.Count -gt 0) { $ipv6Addresses -join ', ' } else { 'No IPv6 address' }

            if ($ipv4Addresses.Count -gt 0) {
                $script:selectedAdapterHasIPv4 = $true
                $selectedInterfaceIP = [System.Net.IPAddress]::Parse($ipv4Addresses[0])
                #Write-Host "Selected Interface IP: $selectedInterfaceIP"

                $connectivityStatus = Get-ConnectivityStatus -selectedInterfaceIP $selectedInterfaceIP

                if ($connectivityStatus.Internet) {
                    Set-StatusCard -Card $internetStatusCard -Text 'Connected' -State Success
                }
                else {
                    Set-StatusCard -Card $internetStatusCard -Text 'No reply' -State Failure
                }

                if ($connectivityStatus.DNS) {
                    Set-StatusCard -Card $dnsStatusCard -Text 'Working' -State Success
                }
                else {
                    Set-StatusCard -Card $dnsStatusCard -Text 'No reply' -State Failure
                }

                Update-DhcpStatusCard
            }
            else {
                Set-StatusCard -Card $internetStatusCard -Text 'No IPv4' -State Failure
                Set-StatusCard -Card $dnsStatusCard -Text 'Not tested' -State Neutral
                Set-StatusCard -Card $dhcpStatusCard -Text 'No IPv4' -State Neutral
            }

            #Write-Host "Setting Capture to Set button text"
            if ($CapturedIPs.ContainsKey($selectedInterface)) {
                $textBoxCapturedIP.Text = $CapturedIPs[$selectedInterface]
            }
            else {
                $textBoxCapturedIP.Text = ""
            }
            Update-CapturedIPButton
        }
        catch {
            Write-Host "Error: $_"
            Set-StatusCard -Card $adapterStatusCard -Text 'Error' -State Failure
            Set-StatusCard -Card $internetStatusCard -Text 'Not tested' -State Neutral
            Set-StatusCard -Card $dnsStatusCard -Text 'Not tested' -State Neutral
            Set-StatusCard -Card $dhcpStatusCard -Text 'Unable to check' -State Failure
            $script:selectedAdapterCanConfigure = $false
            $script:selectedAdapterHasIPv4 = $false
            $lblAdapterTypeValue.Text = 'Unable to identify adapter'
            $lblMacAddressValue.Text = 'Unable to retrieve MAC address'
            $lblIPv4Value.Text = 'Unable to retrieve address information'
            $lblPrefixValue.Text = ([char]0x2014).ToString()
            $lblIPv6Value.Text = ([char]0x2014).ToString()
            $configNoticeLabel.Text = 'Adapter configuration is unavailable.'
        }
        finally {
            ButtonGroupEnable($true)
            $form.UseWaitCursor = $false
        }
    }
    else {
        Write-Host "No interface selected"
    }
}

# Function to capture the current IPv4 of the selected interface
function Capture-Current-IPv4 {
    $selectedInterface = $script:selectedInterface

    if ($selectedInterface) {
        $currentIPv4 = (Get-NetIPAddress -InterfaceAlias $selectedInterface -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1).IPAddress
        if ([string]::IsNullOrWhiteSpace($currentIPv4)) {
            [Windows.Forms.MessageBox]::Show('This adapter does not currently have an IPv4 address.', 'No IPv4 Address') | Out-Null
            return
        }
        # Write-Host "Captured current IPv4 for $($selectedInterface): $($currentIPv4)"

        # Store the captured IPv4 in a variable unique to the adapter
        $CapturedIPs[$selectedInterface] = $currentIPv4

        $textBoxCapturedIP.Text = $currentIPv4
    }
}

function ValidateSubnetMask {
    param(
        [string]$subnet
    )

    $prefix = Convert-SubnetMaskToPrefix -SubnetMask $subnet
    if ($null -eq $prefix) {
        return $null
    }

    return [System.Net.IPAddress]::Parse((Convert-PrefixToSubnetMask -PrefixLength $prefix))
}

# Function to set the captured IP using Netsh
function Set-Captured-IP {
    $selectedInterface = $script:selectedInterface

    if ($selectedInterface -ne $null -and $CapturedIPs.ContainsKey($selectedInterface)) {
        $capturedIP = $CapturedIPs[$selectedInterface].ToString().Trim()
        if (-not (Test-ValidIPv4Address -Address $capturedIP)) {
            [Windows.Forms.MessageBox]::Show(
                'Enter a valid IPv4 address using four numbers from 0 to 255 (for example, 192.168.1.25).',
                'Invalid IPv4 Address',
                [Windows.Forms.MessageBoxButtons]::OK,
                [Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
            return
        }

        # Write-Host "Setting IP for $($selectedInterface): $($capturedIP)"

        $desired_subnet = ValidateSubnetMask($textBoxCapturedSubnet.Text)
        if ($null -eq $desired_subnet) {
            [Windows.Forms.MessageBox]::Show(
                'Enter a valid contiguous subnet mask or choose a CIDR prefix.',
                'Invalid Subnet Mask',
                [Windows.Forms.MessageBoxButtons]::OK,
                [Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
            return
        }
        # Write-Host "Desired subnet: $desired_subnet"

        $currentIPv4Addresses = @(Get-NetIPAddress -InterfaceAlias $selectedInterface -AddressFamily IPv4 -ErrorAction SilentlyContinue | ForEach-Object { $_.IPAddress })
        $addressAlreadyOnAdapter = $currentIPv4Addresses -contains $capturedIP
        $sourceAddress = $currentIPv4Addresses | Select-Object -First 1

        if (-not $addressAlreadyOnAdapter) {
            $addressInUse = Test-IPv4AddressInUse -Address $capturedIP -SourceAddress $sourceAddress
            if ($addressInUse) {
                $confirmation = [Windows.Forms.MessageBox]::Show(
                    "The address $capturedIP replied to ping and may already be in use by another device.`r`n`r`nDo you want to assign it anyway?",
                    'Possible IP Address Conflict',
                    [Windows.Forms.MessageBoxButtons]::YesNo,
                    [Windows.Forms.MessageBoxIcon]::Warning,
                    [Windows.Forms.MessageBoxDefaultButton]::Button2
                )

                if ($confirmation -ne [Windows.Forms.DialogResult]::Yes) {
                    return
                }
            }
        }

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
    $selectedInterface = $script:selectedInterface

    if ($selectedInterface -ne $null) {
        # Write-Host "Setting Random Link Local IP for $($selectedInterface)"

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
                # Write-Host "IP address $randomIp is in use. Generating a new one..."
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

# Apply accessibility-sensitive theme details, including Windows High Contrast.
Apply-AppTheme -Mode $script:themeMode

# Keep interface actions disabled until the user selects an interface.
ButtonGroupEnable($false)

$dhcpHealthTimer = New-Object System.Windows.Forms.Timer
$dhcpHealthTimer.Interval = 2000
$dhcpHealthTimer.Add_Tick({
        if ($null -ne $script:dhcpServer -and -not $script:dhcpServer.IsRunning -and
            -not [string]::IsNullOrWhiteSpace($script:dhcpFirewallRuleName)) {
            $serverError = $script:dhcpServer.LastError
            Remove-DhcpFirewallRule
            Update-DhcpServerButton
            Update-DhcpStatusCard
            ButtonGroupEnable($true)
            if (-not [string]::IsNullOrWhiteSpace($serverError)) {
                $configNoticeLabel.Text = "DHCP server stopped: $serverError"
            }
        }
    })

# Set form event handler
$form.Add_Shown({
        [NICChangerNativeV2]::SetDarkTitleBar($form.Handle, $script:themeMode -eq 'Dark')
        Get-NetworkInterface
        $dhcpHealthTimer.Start()
    })

$form.Add_FormClosing({
        $dhcpHealthTimer.Stop()
        if ($null -ne $script:dhcpStatusRetryTimer) {
            $script:dhcpStatusRetryTimer.Stop()
            $script:dhcpStatusRetryTimer.Dispose()
            $script:dhcpStatusRetryTimer = $null
        }
        Stop-NICChangerDhcpServer
    })

$form.Add_FormClosed({
        $dhcpHealthTimer.Dispose()
    })

# Display the form
[Windows.Forms.Application]::Run($form)
