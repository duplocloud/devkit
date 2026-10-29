// Enables only control-flow obfuscation and code virtualization. The other ArmDot features stay off because
// they break the reflection-heavy extension host at startup.
[assembly: ArmDot.Client.ObfuscateControlFlow]
[assembly: ArmDot.Client.VirtualizeCode]
