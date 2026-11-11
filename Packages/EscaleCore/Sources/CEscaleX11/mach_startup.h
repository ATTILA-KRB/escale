/* Genere par mig (Xcode) depuis mach_startup.defs de xorg-server 21.1.23 (hw/xquartz/mach-startup), copyright (c) 2008 Apple Inc., licence MIT (voir mach_startup.defs). Ne pas modifier : scripts/x11-bundle.sh ne le regenere pas. */
#ifndef	_mach_startup_user_
#define	_mach_startup_user_

/* Module mach_startup */

#include <string.h>
#include <mach/ndr.h>
#include <mach/boolean.h>
#include <mach/kern_return.h>
#include <mach/notify.h>
#include <mach/mach_types.h>
#include <mach/message.h>
#include <mach/mig_errors.h>
#include <mach/port.h>
	
/* BEGIN VOUCHER CODE */

#ifndef KERNEL
#if defined(__has_include)
#if __has_include(<mach/mig_voucher_support.h>)
#ifndef USING_VOUCHERS
#define USING_VOUCHERS
#endif
#ifndef __VOUCHER_FORWARD_TYPE_DECLS__
#define __VOUCHER_FORWARD_TYPE_DECLS__
#ifdef __cplusplus
extern "C" {
#endif
#ifndef __VOUCHER_FOWARD_TYPE_DECLS_SINGLE_ATTR
#define __VOUCHER_FOWARD_TYPE_DECLS_SINGLE_ATTR __unsafe_indexable
#endif
	extern boolean_t voucher_mach_msg_set(mach_msg_header_t * msg) __attribute__((weak_import));
#ifdef __cplusplus
}
#endif
#endif // __VOUCHER_FORWARD_TYPE_DECLS__
#endif // __has_include(<mach/mach_voucher_types.h>)
#endif // __has_include
#endif // !KERNEL
	
/* END VOUCHER CODE */

	
/* BEGIN MIG_STRNCPY_ZEROFILL CODE */

#if defined(__has_include)
#if __has_include(<mach/mig_strncpy_zerofill_support.h>)
#ifndef USING_MIG_STRNCPY_ZEROFILL
#define USING_MIG_STRNCPY_ZEROFILL
#endif
#ifndef __MIG_STRNCPY_ZEROFILL_FORWARD_TYPE_DECLS__
#define __MIG_STRNCPY_ZEROFILL_FORWARD_TYPE_DECLS__
#ifdef __cplusplus
extern "C" {
#endif
#ifndef __MIG_STRNCPY_ZEROFILL_FORWARD_TYPE_DECLS_CSTRING_ATTR
#define __MIG_STRNCPY_ZEROFILL_FORWARD_TYPE_DECLS_CSTRING_COUNTEDBY_ATTR(C) __unsafe_indexable
#endif
	extern int mig_strncpy_zerofill(char * dest, const char * src, int len) __attribute__((weak_import));
#ifdef __cplusplus
}
#endif
#endif /* __MIG_STRNCPY_ZEROFILL_FORWARD_TYPE_DECLS__ */
#endif /* __has_include(<mach/mig_strncpy_zerofill_support.h>) */
#endif /* __has_include */
	
/* END MIG_STRNCPY_ZEROFILL CODE */


#ifdef AUTOTEST
#ifndef FUNCTION_PTR_T
#define FUNCTION_PTR_T
typedef void (*function_ptr_t)(mach_port_t, char *, mach_msg_type_number_t);
typedef struct {
        char            * name;
        function_ptr_t  function;
} function_table_entry;
typedef function_table_entry   *function_table_t;
#endif /* FUNCTION_PTR_T */
#endif /* AUTOTEST */

#ifndef	mach_startup_MSG_COUNT
#define	mach_startup_MSG_COUNT	3
#endif	/* mach_startup_MSG_COUNT */

#include <Availability.h>
#include <mach/std_types.h>
#include <mach/mig.h>
#include <mach/mig.h>
#include <mach/mach_types.h>
#include "mach_startup_types.h"

#ifdef __BeforeMigUserHeader
__BeforeMigUserHeader
#endif /* __BeforeMigUserHeader */

#include <sys/cdefs.h>
__BEGIN_DECLS


/* Routine start_x11_server */
#ifdef	mig_external
mig_external
#else
extern
#endif	/* mig_external */
kern_return_t start_x11_server
(
	mach_port_t port,
	string_array_t argv,
	mach_msg_type_number_t argvCnt,
	string_array_t envp,
	mach_msg_type_number_t envpCnt
);

/* Routine request_fd_handoff_socket */
#ifdef	mig_external
mig_external
#else
extern
#endif	/* mig_external */
kern_return_t request_fd_handoff_socket
(
	mach_port_t port,
	string_t socket_filename
);

/* Routine request_pid */
#ifdef	mig_external
mig_external
#else
extern
#endif	/* mig_external */
kern_return_t request_pid
(
	mach_port_t port,
	int *pid
);

__END_DECLS

/********************** Caution **************************/
/* The following data types should be used to calculate  */
/* maximum message sizes only. The actual message may be */
/* smaller, and the position of the arguments within the */
/* message layout may vary from what is presented here.  */
/* For example, if any of the arguments are variable-    */
/* sized, and less than the maximum is sent, the data    */
/* will be packed tight in the actual message to reduce  */
/* the presence of holes.                                */
/********************** Caution **************************/

/* typedefs for all requests */

#ifndef __Request__mach_startup_subsystem__defined
#define __Request__mach_startup_subsystem__defined

#ifdef  __MigPackStructs
#pragma pack(push, 4)
#endif
	typedef struct {
		mach_msg_header_t Head;
		/* start of the kernel processed data */
		mach_msg_body_t msgh_body;
		mach_msg_ool_descriptor_t argv;
		mach_msg_ool_descriptor_t envp;
		/* end of the kernel processed data */
		NDR_record_t NDR;
		mach_msg_type_number_t argvCnt;
		mach_msg_type_number_t envpCnt;
	} __Request__start_x11_server_t __attribute__((unused));
#ifdef  __MigPackStructs
#pragma pack(pop)
#endif

#ifdef  __MigPackStructs
#pragma pack(push, 4)
#endif
	typedef struct {
		mach_msg_header_t Head;
	} __Request__request_fd_handoff_socket_t __attribute__((unused));
#ifdef  __MigPackStructs
#pragma pack(pop)
#endif

#ifdef  __MigPackStructs
#pragma pack(push, 4)
#endif
	typedef struct {
		mach_msg_header_t Head;
	} __Request__request_pid_t __attribute__((unused));
#ifdef  __MigPackStructs
#pragma pack(pop)
#endif
#endif /* !__Request__mach_startup_subsystem__defined */

/* union of all requests */

#ifndef __RequestUnion__mach_startup_subsystem__defined
#define __RequestUnion__mach_startup_subsystem__defined
union __RequestUnion__mach_startup_subsystem {
	__Request__start_x11_server_t Request_start_x11_server;
	__Request__request_fd_handoff_socket_t Request_request_fd_handoff_socket;
	__Request__request_pid_t Request_request_pid;
};
#endif /* !__RequestUnion__mach_startup_subsystem__defined */
/* typedefs for all replies */

#ifndef __Reply__mach_startup_subsystem__defined
#define __Reply__mach_startup_subsystem__defined

#ifdef  __MigPackStructs
#pragma pack(push, 4)
#endif
	typedef struct {
		mach_msg_header_t Head;
		NDR_record_t NDR;
		kern_return_t RetCode;
	} __Reply__start_x11_server_t __attribute__((unused));
#ifdef  __MigPackStructs
#pragma pack(pop)
#endif

#ifdef  __MigPackStructs
#pragma pack(push, 4)
#endif
	typedef struct {
		mach_msg_header_t Head;
		NDR_record_t NDR;
		kern_return_t RetCode;
		string_t socket_filename;
	} __Reply__request_fd_handoff_socket_t __attribute__((unused));
#ifdef  __MigPackStructs
#pragma pack(pop)
#endif

#ifdef  __MigPackStructs
#pragma pack(push, 4)
#endif
	typedef struct {
		mach_msg_header_t Head;
		NDR_record_t NDR;
		kern_return_t RetCode;
		int pid;
	} __Reply__request_pid_t __attribute__((unused));
#ifdef  __MigPackStructs
#pragma pack(pop)
#endif
#endif /* !__Reply__mach_startup_subsystem__defined */

/* union of all replies */

#ifndef __ReplyUnion__mach_startup_subsystem__defined
#define __ReplyUnion__mach_startup_subsystem__defined
union __ReplyUnion__mach_startup_subsystem {
	__Reply__start_x11_server_t Reply_start_x11_server;
	__Reply__request_fd_handoff_socket_t Reply_request_fd_handoff_socket;
	__Reply__request_pid_t Reply_request_pid;
};
#endif /* !__RequestUnion__mach_startup_subsystem__defined */

#ifndef subsystem_to_name_map_mach_startup
#define subsystem_to_name_map_mach_startup \
    { "start_x11_server", 1000 },\
    { "request_fd_handoff_socket", 1001 },\
    { "request_pid", 1002 }
#endif

#ifdef __AfterMigUserHeader
__AfterMigUserHeader
#endif /* __AfterMigUserHeader */

#endif	 /* _mach_startup_user_ */
