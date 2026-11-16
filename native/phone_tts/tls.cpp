// The implementation is API9's unmodified compiler-rt emutls.c.o with its
// hidden entry point renamed at build time. Only this forwarding symbol is new.
extern "C" void* GameVoicePrivateEmutls(void*);
extern "C" __attribute__((visibility("default"))) void* __emutls_get_address(void* control)
{
    return GameVoicePrivateEmutls(control);
}
