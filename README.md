# Asistencia de Baile Urbano

App para que cada profe pase lista en sus clases de baile urbano. By The Wild Side.

## Cómo funciona
- Cada profe entra con **su código** (12 letras y números). Solo ve sus clases y sus niños.
- Los datos se guardan en el móvil y en Supabase (proyecto **Asistencia Baile**, Frankfurt). Si no hay cobertura, se guardan en el móvil y se suben solos al volver.
- El código de **administrador** abre además la pestaña **Profes**: ver a todas las profes, crear códigos nuevos y desactivarlos.

## Dar acceso a una profe nueva
1. Abre la app con tu código de administrador.
2. Pestaña **Profes** › **Nueva profe** › escribe su nombre › **Crear código**.
3. Pulsa **Copiar mensaje** y pégalo en WhatsApp. Lleva el enlace y su código.

## Quitar el acceso
Pestaña **Profes** › toca a la profe › **Desactivar**. Sus datos se quedan guardados por si la vuelves a activar.

## Archivos
- `index.html`: la app entera.
- `sw.js`: hace que funcione sin conexión. **Sube `VERSION`** cada vez que cambies algo.
- `legal.html`: privacidad.
- `supabase/esquema.sql`: tablas y funciones de la base de datos.

## Pendiente para más adelante
- Poner un email de contacto de The Wild Side en `legal.html`.
- Plan gratuito de Supabase: el proyecto se pausa si pasa una semana sin que nadie use la app; se reactiva desde supabase.com.
