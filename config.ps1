$ApiUrl = "http://localhost:8080/v1/chat/completions" # Update port if using LM Studio (1234) or Ollama (11434)

# Source groups ordered by importance
$SourceGroups = @(
    @{
        Category = "Security"
        Mode     = "ids"
        Logs     = "Security"
        Ids      = @(4625, 4648, 4672, 4720, 4726, 4732, 4740, 4776)
        # 4625=logon failure, 4648=explicit credentials, 4672=special privileges,
        # 4720=account created, 4726=account deleted, 4732=group change, 4740=lockout, 4776=NTLM failure
    },
    @{
        Category = "Hardware & Storage"
        Mode     = "levels"
        Logs     = @('Hardware Events', 'Microsoft-Windows-Ntfs/Operational')
    },
    @{
        Category = "Crashes & Services"
        Mode     = "ids"
        Logs     = "System"
        Ids      = @(41, 1001, 6008, 7000, 7001, 7009, 7011, 7031, 7034)
        # 41=unexpected reboot, 1001=bugcheck, 6008=unexpected shutdown,
        # 7000/7001/7009/7011/7031/7034=service failures
    },
    @{
        Category = "System"
        Mode     = "levels"
        Logs     = 'System'
        ExcludeIds = @(41, 1001, 6008, 7000, 7001, 7009, 7011, 7031, 7034)
    },
    @{
        Category = "Application"
        Mode     = "levels"
        Logs     = 'Application'
    },
    @{
        Category = "Network"
        Mode     = "levels"
        Logs     = @(
            'Microsoft-Windows-NetworkProfile/Operational',
            'Microsoft-Windows-DNS-Client/Operational',
            'Microsoft-Windows-Dhcp-Client/Operational',
            'Microsoft-Windows-TCPIP/Operational'
        )
    },
    @{
        Category = "Performance"
        Mode     = "levels"
        Logs     = @('Microsoft-Windows-Diagnostics-Performance/Operational', 'Microsoft-Windows-WMI-Activity/Operational')
    },
    @{
        Category = "Antivirus & Defense"
        Mode     = "levels"
        Logs     = @('Microsoft-Windows-Windows Defender/Operational')
    },
    @{
        Category = "Updates & Tasks"
        Mode     = "levels"
        Logs     = @('Microsoft-Windows-WindowsUpdateClient/Operational', 'Microsoft-Windows-Bits-Client/Operational', 'Microsoft-Windows-TaskScheduler/Operational')
    }
)
