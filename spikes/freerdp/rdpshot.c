/*
 * Spike FreeRDP : client minimal qui se connecte, laisse GDI composer le bureau distant
 * (gdi_init, 32 bpp) et ecrit une capture PNG.
 *
 * Usage : rdpshot <hote> <port> <utilisateur|-> <motdepasse|-> <sortie.png> [secondes_max] [LxH] [nla|tls]
 * Le mot de passe passe en argument ici parce que c'est un outil de test jetable ; l'app lirait le Keychain.
 * Codes de sortie : 0 capture ecrite, 2 echec de connexion (code FreeRDP affiche), 3 pas d'image, 4 erreur interne.
 * Jetable : le certificat serveur est accepte sans verification (IgnoreCertificate), a ne PAS reproduire dans l'app.
 */
#include <freerdp/freerdp.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/client.h>
#include <freerdp/error.h>
#include <freerdp/settings.h>
#include <freerdp/input.h>
#include <freerdp/channels/channels.h>
#include <freerdp/client/channels.h>
#include <winpr/synch.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <zlib.h>

typedef struct
{
	rdpClientContext common;
	unsigned frames;
	double firstFrame; /* horodatage du premier EndPaint */
	double lastFrame;
} SpikeContext;

static double now(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

/* ---- PNG minimal (RGB 8 bits, un seul IDAT zlib) ---- */
static void put32(unsigned char* p, uint32_t v)
{
	p[0] = (unsigned char)(v >> 24);
	p[1] = (unsigned char)(v >> 16);
	p[2] = (unsigned char)(v >> 8);
	p[3] = (unsigned char)v;
}

static int chunk(FILE* f, const char* type, const unsigned char* data, uint32_t len)
{
	unsigned char hdr[8];
	put32(hdr, len);
	memcpy(hdr + 4, type, 4);
	uLong crc = crc32(0L, (const Bytef*)type, 4);
	if (len)
		crc = crc32(crc, data, len);
	unsigned char tail[4];
	put32(tail, (uint32_t)crc);
	if (fwrite(hdr, 1, 8, f) != 8 || (len && fwrite(data, 1, len, f) != len) ||
	    fwrite(tail, 1, 4, f) != 4)
		return -1;
	return 0;
}

static int write_png(const char* path, const unsigned char* bgrx, int w, int h, int stride)
{
	size_t rowLen = 1 + (size_t)w * 3;
	unsigned char* raw = malloc(rowLen * (size_t)h);
	if (!raw)
		return -1;
	for (int y = 0; y < h; y++)
	{
		unsigned char* d = raw + rowLen * (size_t)y;
		const unsigned char* s = bgrx + (size_t)y * (size_t)stride;
		*d++ = 0; /* filtre None */
		for (int x = 0; x < w; x++, s += 4)
		{
			*d++ = s[2];
			*d++ = s[1];
			*d++ = s[0];
		}
	}
	uLongf zlen = compressBound((uLong)(rowLen * (size_t)h));
	unsigned char* z = malloc(zlen);
	if (!z || compress2(z, &zlen, raw, (uLong)(rowLen * (size_t)h), 6) != Z_OK)
	{
		free(raw);
		free(z);
		return -1;
	}
	FILE* f = fopen(path, "wb");
	int rc = -1;
	if (f)
	{
		static const unsigned char sig[8] = { 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a };
		unsigned char ihdr[13];
		put32(ihdr, (uint32_t)w);
		put32(ihdr + 4, (uint32_t)h);
		ihdr[8] = 8;
		ihdr[9] = 2; /* RGB */
		ihdr[10] = ihdr[11] = ihdr[12] = 0;
		if (fwrite(sig, 1, 8, f) == 8 && chunk(f, "IHDR", ihdr, 13) == 0 &&
		    chunk(f, "IDAT", z, (uint32_t)zlen) == 0 && chunk(f, "IEND", NULL, 0) == 0)
			rc = 0;
		fclose(f);
	}
	free(raw);
	free(z);
	return rc;
}

/* ---- Callbacks FreeRDP ---- */
static BOOL spike_begin_paint(rdpContext* context)
{
	rdpGdi* gdi = context->gdi;
	gdi->primary->hdc->hwnd->invalid->null = TRUE;
	return TRUE;
}

static BOOL spike_end_paint(rdpContext* context)
{
	SpikeContext* sc = (SpikeContext*)context;
	sc->frames++;
	sc->lastFrame = now();
	if (sc->firstFrame == 0)
		sc->firstFrame = sc->lastFrame;
	return TRUE;
}

static BOOL spike_desktop_resize(rdpContext* context)
{
	rdpSettings* s = context->settings;
	return gdi_resize(context->gdi, freerdp_settings_get_uint32(s, FreeRDP_DesktopWidth),
	                  freerdp_settings_get_uint32(s, FreeRDP_DesktopHeight));
}

static BOOL spike_pre_connect(freerdp* instance)
{
	/* Sans X11/ffmpeg : on n'a besoin que des canaux statiques. */
	return freerdp_client_load_addins(instance->context->channels, instance->context->settings);
}

static BOOL spike_post_connect(freerdp* instance)
{
	rdpContext* ctx = instance->context;
	if (!gdi_init(instance, PIXEL_FORMAT_BGRX32))
		return FALSE;
	ctx->update->BeginPaint = spike_begin_paint;
	ctx->update->EndPaint = spike_end_paint;
	ctx->update->DesktopResize = spike_desktop_resize;
	return TRUE;
}

static void spike_post_disconnect(freerdp* instance)
{
	gdi_free(instance);
}

/* Appele quand le serveur demande des identifiants et qu'on n'en a pas : on echoue proprement. */
static BOOL spike_authenticate(freerdp* instance, char** username, char** password, char** domain,
                               rdp_auth_reason reason)
{
	(void)reason;
	(void)instance;
	(void)username;
	(void)password;
	(void)domain;
	fprintf(stderr, "[spike] identifiants demandes par le serveur : refus (aucun fourni)\n");
	return FALSE;
}

static DWORD spike_verify_cert(freerdp* instance, const char* host, UINT16 port, const char* common_name,
                               const char* subject, const char* issuer, const char* fingerprint,
                               DWORD flags)
{
	(void)instance;
	(void)flags;
	fprintf(stderr, "[spike] certificat %s:%u CN=%s\n[spike]   sujet=%s\n[spike]   emetteur=%s\n[spike]   empreinte=%s\n",
	        host, port, common_name, subject, issuer, fingerprint);
	return 2; /* 2 = accepter pour cette session seulement (jamais memorise) */
}

static BOOL spike_client_new(freerdp* instance, rdpContext* context)
{
	(void)context;
	instance->PreConnect = spike_pre_connect;
	instance->PostConnect = spike_post_connect;
	instance->PostDisconnect = spike_post_disconnect;
	instance->AuthenticateEx = spike_authenticate;
	(void)spike_verify_cert; /* IgnoreCertificate=TRUE : pas de callback dans ce spike */
	return TRUE;
}

static void spike_client_free(freerdp* instance, rdpContext* context)
{
	(void)instance;
	(void)context;
}

static int spike_client_start(rdpContext* c)
{
	(void)c;
	return 0;
}

static int spike_client_stop(rdpContext* c)
{
	(void)c;
	return 0;
}

static int entry(RDP_CLIENT_ENTRY_POINTS* ep)
{
	memset(ep, 0, sizeof(*ep));
	ep->Version = RDP_CLIENT_INTERFACE_VERSION;
	ep->Size = sizeof(RDP_CLIENT_ENTRY_POINTS_V1);
	ep->ContextSize = sizeof(SpikeContext);
	ep->ClientNew = spike_client_new;
	ep->ClientFree = spike_client_free;
	ep->ClientStart = spike_client_start;
	ep->ClientStop = spike_client_stop;
	return 0;
}

#define CHECK(x)                                                         \
	do                                                                   \
	{                                                                    \
		if (!(x))                                                        \
		{                                                                \
			fprintf(stderr, "[spike] reglage refuse : %s\n", #x);        \
			return 4;                                                    \
		}                                                                \
	} while (0)

int main(int argc, char** argv)
{
	if (argc < 6)
	{
		fprintf(stderr, "usage: %s hote port utilisateur|- motdepasse|- sortie.png [secondes] [LxH] [nla|tls]\n", argv[0]);
		return 4;
	}
	const char* host = argv[1];
	unsigned port = (unsigned)atoi(argv[2]);
	const char* user = strcmp(argv[3], "-") ? argv[3] : NULL;
	const char* pass = strcmp(argv[4], "-") ? argv[4] : NULL;
	const char* out = argv[5];
	double maxSecs = argc > 6 ? atof(argv[6]) : 20;
	unsigned w = 1280, h = 720;
	if (argc > 7)
		sscanf(argv[7], "%ux%u", &w, &h);
	int nla = !(argc > 8 && strcmp(argv[8], "tls") == 0);

	RDP_CLIENT_ENTRY_POINTS ep;
	entry(&ep);
	rdpContext* ctx = freerdp_client_context_new(&ep);
	if (!ctx)
		return 4;
	SpikeContext* sc = (SpikeContext*)ctx;
	rdpSettings* s = ctx->settings;

	CHECK(freerdp_settings_set_string(s, FreeRDP_ServerHostname, host));
	CHECK(freerdp_settings_set_uint32(s, FreeRDP_ServerPort, port));
	if (user)
		CHECK(freerdp_settings_set_string(s, FreeRDP_Username, user));
	if (pass)
		CHECK(freerdp_settings_set_string(s, FreeRDP_Password, pass));
	CHECK(freerdp_settings_set_uint32(s, FreeRDP_DesktopWidth, w));
	CHECK(freerdp_settings_set_uint32(s, FreeRDP_DesktopHeight, h));
	CHECK(freerdp_settings_set_uint32(s, FreeRDP_ColorDepth, 32));
	CHECK(freerdp_settings_set_bool(s, FreeRDP_SoftwareGdi, TRUE));
	CHECK(freerdp_settings_set_bool(s, FreeRDP_IgnoreCertificate, TRUE));
	CHECK(freerdp_settings_set_bool(s, FreeRDP_NlaSecurity, nla));
	CHECK(freerdp_settings_set_bool(s, FreeRDP_TlsSecurity, TRUE));
	CHECK(freerdp_settings_set_bool(s, FreeRDP_RdpSecurity, FALSE));
	CHECK(freerdp_settings_set_bool(s, FreeRDP_AutoLogonEnabled, pass != NULL));
	CHECK(freerdp_settings_set_bool(s, FreeRDP_SupportGraphicsPipeline, TRUE));
	CHECK(freerdp_settings_set_bool(s, FreeRDP_GfxH264, FALSE));
	CHECK(freerdp_settings_set_bool(s, FreeRDP_GfxAVC444, FALSE));
	CHECK(freerdp_settings_set_bool(s, FreeRDP_RemoteFxCodec, TRUE));
	CHECK(freerdp_settings_set_bool(s, FreeRDP_FastPathOutput, TRUE));
	CHECK(freerdp_settings_set_uint32(s, FreeRDP_ConnectionType, CONNECTION_TYPE_AUTODETECT));
	CHECK(freerdp_settings_set_bool(s, FreeRDP_SupportDisplayControl, TRUE));
	CHECK(freerdp_settings_set_bool(s, FreeRDP_RedirectClipboard, TRUE));

	if (freerdp_client_start(ctx) != 0)
		return 4;
	freerdp* inst = ctx->instance;
	double t0 = now();
	int rc = 2;
	int moved = 0;
	if (!freerdp_connect(inst))
	{
		UINT32 err = freerdp_get_last_error(ctx);
		fprintf(stderr, "[spike] CONNEXION ECHOUEE : 0x%08X (%s / %s)\n", err,
		        freerdp_get_last_error_name(err), freerdp_get_last_error_string(err));
		printf("RESULT connect_failed code=0x%08X name=%s\n", err, freerdp_get_last_error_name(err));
		goto done;
	}
	printf("[spike] connecte en %.2f s, bureau %ux%u\n", now() - t0,
	       freerdp_settings_get_uint32(s, FreeRDP_DesktopWidth),
	       freerdp_settings_get_uint32(s, FreeRDP_DesktopHeight));

	while (!freerdp_shall_disconnect_context(ctx))
	{
		HANDLE handles[MAXIMUM_WAIT_OBJECTS] = { 0 };
		DWORD n = freerdp_get_event_handles(ctx, handles, ARRAYSIZE(handles));
		if (n == 0)
			break;
		DWORD st = WaitForMultipleObjects(n, handles, FALSE, 200);
		if (st == WAIT_FAILED || !freerdp_check_event_handles(ctx))
			break;
		double t = now();
		/* Prouve le chemin d'entree : un deplacement de souris apres la premiere image
		 * (le serveur d'exemple dessine alors son icone a la position du curseur). */
		if (sc->frames > 0 && !moved)
		{
			moved = 1;
			for (int i = 0; i < 5; i++)
				freerdp_input_send_mouse_event(ctx->input, PTR_FLAGS_MOVE, (UINT16)(300 + i * 20), (UINT16)(200 + i * 10));
			unsigned before = sc->frames;
			double tm = now();
			while (sc->frames == before && now() - tm < 3)
			{
				DWORD n2 = freerdp_get_event_handles(ctx, handles, ARRAYSIZE(handles));
				WaitForMultipleObjects(n2, handles, FALSE, 100);
				if (!freerdp_check_event_handles(ctx))
					break;
			}
			continue;
		}
		/* Capture quand le bureau est stable (1,5 s sans nouvelle image) ou au delai max. */
		if (sc->frames > 0 && t - sc->lastFrame > 1.5)
			break;
		if (t - t0 > maxSecs)
			break;
	}
	if (ctx->gdi && ctx->gdi->primary_buffer && sc->frames > 0)
	{
		rdpGdi* g = ctx->gdi;
		if (write_png(out, g->primary_buffer, g->width, g->height, (int)g->stride) == 0)
		{
			printf("RESULT ok png=%s %dx%d frames=%u\n", out, g->width, g->height, sc->frames);
			rc = 0;
		}
		else
			rc = 4;
	}
	else
	{
		printf("RESULT no_image frames=%u last_error=0x%08X\n", sc->frames, freerdp_get_last_error(ctx));
		rc = 3;
	}
	freerdp_disconnect(inst);
done:
	freerdp_client_stop(ctx);
	freerdp_client_context_free(ctx);
	return rc;
}
