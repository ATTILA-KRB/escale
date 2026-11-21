// Captures réelles de l'app, par nom de fichier (sans extension). Source unique pour Shot et Landing.
// Boucles vidéo optionnelles : public/clips/<nom>.mp4, détectées au build (aucun cadre vide si le fichier manque).
import { existsSync } from 'node:fs';
import { resolve } from 'node:path';
import type { ImageMetadata } from 'astro';

const files = import.meta.glob<{ default: ImageMetadata }>('/src/assets/shots/*.png', { eager: true });

export const shot = (name: string): ImageMetadata | undefined => files[`/src/assets/shots/${name}.png`]?.default;

// Les scripts npm tournent depuis la racine web/ : on y résout public/.
const publicFile = (rel: string) => resolve(process.cwd(), 'public', rel);

/** URL publique de la boucle vidéo d'une fonction, ou undefined si le fichier n'existe pas. */
export const clip = (name: string): string | undefined =>
  existsSync(publicFile(`clips/${name}.mp4`)) ? `/clips/${name}.mp4` : undefined;

/** Vrai si la fonction a de quoi s'afficher (capture ou vidéo). */
export const hasMedia = (name: string): boolean => !!shot(name) || !!clip(name);

/** Image de partage (public/og.png) : balises og:image émises seulement si elle existe. */
export const hasOgImage = (): boolean => existsSync(publicFile('og.png'));
