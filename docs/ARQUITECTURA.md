# Allka Archivo — Arquitectura de la versión 1

Estado: aprobada el 26/11/2026. En construcción (Fase 1: contratos). [English version](ARCHITECTURE.md)

## En una frase

Una tienda con mercado de reventa donde cada prenda única de allka es un NFT en Conflux eSpace. Todo se paga en USDT0. La prenda física ya está hecha y guardada, y se entrega cuando el dueño del NFT la reclama.

## Las piezas

| Pieza | Qué hace |
|---|---|
| Contrato Prenda (NFT) | Es el contrato permanente. Un NFT por cada prenda física, con su talle. Guarda las reglas de guarda de cada drop y hace el reclamo: al reclamar, el NFT se quema. |
| Contrato Venta | Los drops: precio en USDT0, fecha de apertura y entrada anticipada para holders de $FGM. Cobra y entrega el NFT en el mismo paso. |
| Contrato Mercado | La reventa: el dueño publica un precio y otro usuario compra. Reparte el pago en el momento: 98% al vendedor, 2% a FGM. |
| Sitio web | Next.js en Vercel, en inglés y español, pensado primero para celular. Pantallas: drops, prenda, mercado, mi colección, reclamar. |
| Servidor y base de datos | Guarda el catálogo (fotos, talles) y los datos de envío y de factura, que se piden recién al reclamar. |
| Panel de administración | Cargar drops sin tocar código, ver los reclamos por despachar y marcar los envíos. |

Venta y Mercado son módulos que se pueden sumar o reemplazar. Prenda no se reemplaza nunca.

## Cómo se mueve la plata

- Venta primaria: el USDT0 va directo de la billetera del comprador a la tesorería de FGM. No hay escrow y ningún contrato retiene fondos.
- Reventa: el USDT0 va directo del comprador al vendedor (98%) y a la tesorería (2%). La comisión es fija en este Mercado: nadie puede subirla.
- Guarda: el período gratis se cuenta desde la venta original. Después se suma una cuota por cada 30 días cumplidos, hasta un máximo fijado en el drop. La paga quien reclama. Ejemplo: con 6 meses gratis, quien reclama en el mes 8 paga 2 cuotas. El derecho a la prenda no vence.
- FGM puede perdonar guarda, nunca subirla.

## Entrada anticipada para holders de $FGM

Antes de cada drop se toma una foto de quién tiene $FGM. Durante la ventana anticipada, cada billetera de esa foto puede comprar una prenda. Después el drop abre para todos. La foto evita que el mismo $FGM pase de billetera en billetera para entrar varias veces.

## Prendas físicas

Toda prenda está terminada, etiquetada con el número de su NFT y guardada antes de que su drop salga a la venta.

## Los cuatro recorridos

1. Comprar: conectar la billetera, autorizar el monto exacto en USDT0 y comprar. El comprador indica el precio que espera pagar; si cambió, la compra no se hace.
2. Revender: la primera vez el dueño le da permiso al Mercado sobre sus NFT; después publica un precio. Cuando otro usuario paga, el NFT cambia de dueño.
3. Reclamar: el sitio revisa antes que se pueda enviar a ese país. El dueño paga la guarda si corresponde y el NFT se quema. El pedido se crea solo a partir de esa quema en la cadena, y los datos de envío valen solo si los firma la misma billetera que quemó. Se pueden corregir hasta el despacho.
4. Cargar un drop: completar el formulario del panel, revisar los valores que el panel muestra de vuelta y firmar. El drop abre como mínimo 24 horas después y se puede cancelar antes de abrir.

## Transferencias

El NFT solo cambia de dueño a través de un Mercado autorizado, y siempre con permiso de su dueño: ningún Mercado, ni actual ni futuro, puede mover un NFT que su dueño no le haya autorizado. Hay un interruptor de una sola vía para liberar las transferencias más adelante.

Límites que conviene saber: el candado no impide que alguien venda su billetera entera, y quien tenga la billetera comprometida no puede pasar el NFT a otra (solo venderlo o reclamar la prenda).

## Qué puede hacer FGM después de vender

- Pausar compras y reventa en una emergencia. Los reclamos no se pausan.
- Autorizar un Mercado nuevo o apagar para siempre uno que falle.
- Liberar las transferencias (no se puede deshacer).
- Cambiar la dirección de la tesorería.
- Perdonar guarda.

Lo que no puede: cambiar el precio de un drop ya creado, subirle la guarda, mover un NFT ajeno, ni volver a vender un número de NFT ya usado.

## Seguridad

- Tres direcciones de FGM: operador (carga drops; no puede cambiar a dónde va la plata), tesorería (recibe los USDT0) y administración (los interruptores de la lista anterior; guardada y sin uso diario).
- El contrato rechaza precios por debajo de un mínimo y guardas por encima de un máximo, para que un error de carga no regale un drop.
- Los contratos solo cobran de quien hace la operación y nunca tienen saldo.
- USDT0 lo controla su emisor, que puede bloquear direcciones y actualizar el token. Por eso la tesorería se puede cambiar y un reclamo sin guarda no toca el token. Antes de mainnet se prueba todo contra el USDT0 real en una copia de la red.
- El servidor despacha solo cuando la quema quedó firme en la cadena (finalizada).
- Datos personales: los mínimos, cifrados, panel con doble factor, se borran después de la entrega y nada va a la cadena.
- Las fotos y los datos de cada NFT quedan sellados con una huella al crear el drop.
- Las claves privadas nunca viven dentro del repositorio.

## Qué necesita el usuario en la versión 1

Una billetera compatible con Conflux eSpace (por ejemplo MetaMask, Fluent u OKX), USDT0 para pagar y unos centavos de CFX para el gas.

## Etapa 2 (después de la versión 1)

Pago con tarjeta a través de un proveedor de checkout para NFT, y acceso con mail, sin que el usuario necesite CFX.

## Lo que falta antes de mainnet

- Auditoría externa de los contratos.
- Revisión legal y contable del modelo, términos y condiciones y política de privacidad.

Una consecuencia del diseño que conviene tener presente: como el derecho a la prenda no vence, la de alguien que pierda su billetera queda guardada para siempre.

## Fases

1. Contratos con sus tests, incluidos los caminos que deben fallar, y despliegue en testnet.
2. Sitio: drops y compra con USDT0.
3. Reventa.
4. Reclamo y panel de administración.
5. Revisión de seguridad interna y lista de control.
6. Auditoría externa de los contratos. Recién después, mainnet.

## Cuándo está terminada la versión 1

En testnet y desde el celular: dos personas compran con USDT0, se revenden un NFT entre ellas, una reclama la prenda, y se carga un drop nuevo sin tocar código. Además pasan los tests de lo que no debe poder hacerse: comprar a otro precio, reclamar un NFT ajeno, mover un NFT por fuera del Mercado.
