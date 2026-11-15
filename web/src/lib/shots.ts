// Captures réelles de l'app, par nom de fichier (sans extension). Source unique pour Shot et Landing.
import type { ImageMetadata } from 'astro';

const files = import.meta.glob<{ default: ImageMetadata }>('/src/assets/shots/*.png', { eager: true });

export const shot = (name: string): ImageMetadata | undefined => files[`/src/assets/shots/${name}.png`]?.default;
