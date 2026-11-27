# ESTADO — Allka Archivo

Última actualización: 27/11/2026

Bitácora del proyecto: decisiones, avance y pendientes. Se lee al empezar cada sesión de trabajo, junto con [CLAUDE.md](CLAUDE.md) y [docs/ARQUITECTURA.md](docs/ARQUITECTURA.md).

## Dónde estamos

- Fase 0 terminada. La arquitectura se aprobó el 26/11/2026, ya corregida tras una revisión de seguridad independiente.
- Fase 1 en curso (contratos).
  - Hecho: proyecto Hardhat 3, pruebas automáticas en cada cambio (CI), el token de prueba `TestUSDT0` y los tres contratos (`Prenda`, `Venta` y `Mercado`) con sus tests. Cuatro revisiones independientes: una de `Prenda`, otra de `Venta`, `Mercado` y los tres juntos, una tercera de lo que cambió después y una cuarta de las correcciones de la tercera. Ninguna encontró fallas críticas ni altas; lo que encontraron está corregido o anotado como límite conocido. También están escritas las decisiones que el dueño aprobó el 26/11/2026.
  - Falta: el despliegue en la testnet de Conflux eSpace, que se hace desde la computadora del dueño.

## Decisiones tomadas

1. Se empieza de cero en este repositorio.
2. Versión 1: se cobra solo en la stablecoin USDT0. El pago con tarjeta y el acceso con mail pasan a la Etapa 2.
3. Reventa: solo en USDT0.
4. Cada NFT es una prenda física concreta, con talle fijo. Toda prenda está terminada, etiquetada y guardada antes de que su drop salga a la venta.
5. Guarda: unos meses gratis y después una cuota en USDT0 que paga quien reclama. El derecho a la prenda no vence.
6. Transferencias: el NFT solo se mueve a través del Mercado del sitio. Interruptor de una sola vía para liberarlas más adelante.
7. Comisión de reventa: 2%, fija en este Mercado. No se puede subir.
8. Entrada anticipada a los drops para holders de $FGM (`0x630427E7241cB373F508D3b0c653d57280e5De81`): por foto de saldos tomada antes del drop, una prenda por billetera durante la ventana anticipada. El token no reparte ganancias.
9. Red Conflux eSpace. Todo en testnet hasta nuevo aviso. Sin escrow. Datos de envío y de factura solo al reclamar.
10. Sitio en inglés y español, primero celular, con Next.js sobre Vercel.
11. Repositorio público en la organización FGM Labs, con licencia MIT.
12. `Prenda` suma cuatro protecciones: perdón de guarda para todas las prendas a la vez, cambio de tesorería que la billetera nueva tiene que confirmar, una llave que solo puede pausar, y un reclamo que lleva el número del pedido.
13. Un drop que ya abrió se puede cerrar para dejar de vender lo que queda.
14. Una oferta de reventa dura como máximo 30 días.

Las decisiones 12 a 14 son del 26/11/2026. El dueño las aprobó aclarando que, mientras todo esté en testnet, se pueden corregir.

## Números por definir

Se cargan por drop. En testnet se usan valores de prueba.

- Meses de guarda gratis, valor de la cuota y máximo acumulado.
- Cuántas horas dura la ventana anticipada y cuánto $FGM hace falta para entrar en la foto.
- Direcciones de operador, tesorería, administración y pausa. La tesorería tiene que ser una billetera propia y no la dirección de depósito de un exchange: para cambiarla, la billetera nueva tiene que confirmar.

Se fijan al desplegar cada módulo y después no se pueden cambiar (para cambiarlos se despliega un módulo nuevo):

- `Venta`: precio mínimo de una prenda, tope máximo de guarda que puede poner un drop y demora mínima entre cargar un drop y que abra. El contrato no acepta menos de 24 horas, salvo en la testnet de Conflux eSpace y en la red simulada de las pruebas.
- `Mercado`: precio mínimo de una oferta. La duración máxima de una oferta, 30 días, quedó escrita como constante en el contrato.

Para la Fase 4:

- Quién paga el envío y los impuestos de aduana, y cómo.
- A qué países se envía.
- Qué pasa si un paquete se pierde después de quemar el NFT.
- Dominio donde va a vivir el sitio.

## Diseño acordado para los contratos

- `Prenda` es el contrato permanente: guarda las reglas de guarda por drop, la lista de quién puede crear NFT (`Venta`) y la lista de Mercados autorizados, y hace el reclamo.
- El Mercado no es operador universal. Hace falta la aprobación normal del dueño (ERC-721); `Prenda` solo limita quién puede ejecutar transferencias. Un Mercado nuevo arranca sin poder sobre ningún NFT. Un Mercado apagado queda bloqueado para siempre, también si después se liberan las transferencias.
- Cuatro direcciones: operador (crea drops, no fija destinatarios de plata), tesorería (recibe; para cambiarla, la nueva tiene que confirmar), administración (interruptores; cambia de manos en dos pasos) y pausa (solo puede pausar).
- Drops: precio mínimo y guarda máxima en el contrato; apertura al menos 24 horas después de crear (el contrato lo exige fuera de la testnet); se puede cerrar en cualquier momento, antes o después de abrir; un número de NFT se vende una sola vez y un número quemado no se vuelve a crear.
- Entrada anticipada: la foto de saldos se publica como una raíz de Merkle por drop; cada billetera de la lista compra una prenda en la ventana anticipada.
- Compra con precio esperado y nombrando el drop; reclamo con guarda máxima aceptada; aprobaciones por el monto exacto; los contratos cobran solo de quien llama y nunca tienen saldo.
- Publicaciones: al comprar se verifica que el vendedor siga siendo el dueño; una publicación deja de valer si el NFT cambió de manos, si venció, si el vendedor le quitó al Mercado el permiso sobre todos sus NFT o si se le quitó el permiso de ese NFT; no revive; precio mínimo; comisión constante del 2%.
- Guarda: período gratis desde la venta original; una cuota por cada 30 días cumplidos después; máximo obligatorio por drop; la administración solo puede bajarla, a una prenda o a todas a la vez, y cada perdón llega como mucho a dos años desde ese momento. Si la guarda es cero, el reclamo no llama al token.
- Reclamo: antes de la quema el sitio valida el país y guarda los datos de envío con un número de pedido; la quema nombra ese número; el pedido se confirma solo desde el evento de quema en la cadena; los datos se pueden corregir hasta el despacho, con la firma de la billetera que quemó; se despacha con el bloque finalizado.
- La pausa frena compras y reventa. Los reclamos no se pausan. Pausar lo pueden hacer la administración y la llave de pausa; reanudar, solo la administración.
- No se usa EIP-3009 en la versión 1. Para la Etapa 2 se usaría la variante que solo puede ejecutar quien recibe (`receiveWithAuthorization`).
- No hay publicaciones reservadas para un comprador.
- Datos del NFT sellados con una huella al crear el drop.
- Datos personales: mínimos, cifrados, panel con doble factor, borrado después de la entrega, nada en la cadena.

Límites conocidos, sin agregar maquinaria: el candado de transferencias no impide vender la billetera entera ni usar una billetera-contrato como envoltorio; quien tenga la billetera comprometida no puede mover el NFT a otra; con un derecho que no vence, la prenda de quien perdió su billetera queda guardada para siempre.

## Cómo quedó `Prenda`

Decisiones tomadas al escribirlo. Las que dicen "a confirmar" son propuestas del equipo técnico que el dueño todavía no vio una por una; se repasan con él antes de mainnet.

- Reclama solo el dueño del NFT. Ni un Mercado con permiso, ni la administración, ni el módulo de venta pueden reclamar por él.
- La guarda de cada NFT (tiempo gratis, cuota y tope) se fija al venderlo y queda guardada en `Prenda`. El tiempo gratis corre desde ese momento.
- Perdonar guarda es dar más tiempo gratis: la fecha solo puede avanzar. Se puede perdonar a una prenda o a todas a la vez; el perdón para todas alcanza también a las prendas que se vendan después. Es la salida si USDT0 dejara de funcionar para este contrato, porque con la guarda en cero el reclamo no toca el token. Como cada perdón llega como mucho a dos años (ver abajo), mientras dure el problema hay que renovarlo antes de que venza.
- A confirmar: cada perdón llega como mucho a dos años desde el momento en que se da. Se puede renovar cuantas veces haga falta. El tope está para que una fecha mal escrita (por ejemplo, en milisegundos en vez de segundos) no regale la guarda para siempre, cosa que no se podría deshacer.
- La moneda de la guarda queda fija al desplegar. La tesorería vive en `Prenda` y los módulos `Venta` y `Mercado` la leen de ahí: un solo cambio alcanza a todo.
- La tesorería cambia en dos pasos: la administración propone y la billetera nueva confirma. Hasta que confirme, la plata sigue yendo a la tesorería anterior. Una dirección que nadie controla nunca llega a ser tesorería, porque nadie puede confirmar por ella. Si la dirección está mal escrita pero es de alguien (otra billetera propia, por ejemplo), esa persona sí podría confirmar: hay que revisarla antes.
- La llave de pausa solo puede pausar. No puede reanudar ni usar ningún otro interruptor. La nombra y la quita la administración.
- El reclamo lleva el número del pedido y lo deja escrito en el aviso de la quema. El contrato no lo revisa: lo usa el servidor para unir la quema con los datos de envío. Queda público para siempre, así que tiene que ser un número sin significado, nunca datos personales ni algo calculado a partir de ellos.
- Cada NFT cuenta cuántas veces cambió de manos. El Mercado lo va a usar para descartar publicaciones hechas por un dueño anterior.
- El NFT se crea sin pasarle el control al comprador en medio de la compra (`_mint` y no `_safeMint`).
- Un NFT no se puede crear ni enviar a la dirección del propio contrato: ahí quedaría perdido.
- Cada módulo de venta y cada Mercado tiene que declarar que fue hecho para este contrato. Es una traba contra registrar por error otra dirección, y hace que la administración no pueda registrar (y después bloquear) billeteras o contratos ajenos.
- El aviso que deja cada NFT al crearse dice qué módulo lo creó.
- `Prenda` lleva dos cuentas de permisos quitados: cuántas veces un dueño le quitó a alguien el permiso sobre todos sus NFT, y cuántas veces se le quitó a alguien el permiso de un NFT puntual (al borrarlo o al dárselo a otro). El Mercado guarda las dos con cada oferta y la descarta si alguna cambió. Quitarle al Mercado el permiso general retira para siempre todas las ofertas de ese dueño en ese Mercado; quitarle el permiso de un NFT retira solo la oferta de ese NFT.
- A confirmar: permisos más estrictos que en un NFT común. Solo los da el dueño, solo a quien puede mover NFT (con las transferencias cerradas, solo a un Mercado autorizado), y un Mercado apagado pierde los que tenía, también a la vista de quien consulte el contrato.
- A confirmar: la dirección web de los datos de los NFT se puede cambiar; lo que no se puede cambiar es la huella de los datos de cada NFT.
- A confirmar: la administración no se puede abandonar, para que el contrato nunca quede sin nadie que pueda pausar o cambiar la tesorería.

Cómo se probó:

- Tests de cada función, incluidos los caminos que deben fallar, con valores al azar para la guarda y el reclamo.
- Dueños que son contratos en vez de billeteras comunes, un token de pago que bloquea cuentas (como puede hacer el emisor de USDT0) y otro que intenta colarse en medio de un reclamo.
- Secuencias al azar de miles de operaciones (ventas, reventas, permisos dados y quitados, reclamos, pausas, perdones, cambios de tesorería) que comparan el contrato contra una contabilidad aparte después de cada paso. Esa contabilidad no le pregunta nada al contrato para decidir qué tiene que pasar.
- Además se rompe el contrato a propósito, una regla por vez, para comprobar que algún test lo nota.

### Revisión independiente de `Prenda` (26/11/2026)

La hizo un revisor aparte, que no vio cómo se escribió el contrato. No encontró fallas críticas ni altas. Encontró una media y varias menores. No reemplaza a la auditoría externa.

Corregido:

- Media: un Mercado con permiso podía pasarle ese permiso a otra dirección, y un Mercado apagado seguía pudiendo hacerlo. Si ese Mercado fallaba o era malicioso, alcanzaba para mover NFT ajenos. Ahora los permisos los da solo el dueño y un Mercado apagado pierde los que tenía.
- Un NFT enviado al propio contrato quedaba perdido. Ahora ese envío se rechaza.
- El aviso de creación de cada NFT no decía qué módulo lo creó. Ahora lo dice.
- Pedir solo que un módulo "sea un contrato" era una traba débil, y dejaba a la administración registrar y bloquear cualquier contrato. Ahora cada módulo declara para qué contrato fue hecho.
- Tests: el revisor mostró 14 cambios al contrato que los tests originales no notaban. Se sumaron tests para todos, más los de la lista de arriba.

Protecciones que propuso el revisor. El dueño las aprobó el 26/11/2026 y ya están en el contrato, con sus tests:

1. Perdón general de guarda. Si el emisor de USDT0 bloqueara la dirección de `Prenda`, o si USDT0 dejara de funcionar, los reclamos con guarda quedan frenados. Antes la única salida era perdonar prenda por prenda; ahora hay un perdón para todas a la vez. Desde la tercera revisión ese perdón llega como mucho a dos años y hay que renovarlo mientras dure el problema.
2. Cambio de tesorería en dos pasos: la billetera nueva tiene que confirmar. Evita mandar la plata a una dirección mal escrita. Pide que la tesorería sea una billetera propia y no la dirección de depósito de un exchange.
3. Una llave que solo puede pausar, para no depender de la llave guardada en una emergencia.
4. El reclamo lleva el número del pedido. Ata la quema a los datos de envío sin depender de una firma, que algunas billeteras-contrato no pueden dar.

Decisiones que quedan abiertas. Ninguna frena la versión 1 en testnet, pero hay que tomarlas antes de mainnet porque `Prenda` después no se puede cambiar:

1. Un tope de guarda fijo dentro de `Prenda`, además del que tenga `Venta`.
2. Qué cubre exactamente la huella de cada NFT. Se define junto con el catálogo, en la Fase 2.
3. Extras opcionales: aviso de cambio de datos (ERC-4906), datos de la colección y cantidad total de NFT.
4. Un rescate para tokens enviados por error al contrato.

Límites conocidos que se suman:

- Que un módulo declare para qué contrato fue hecho no prueba que sea seguro. Cada módulo necesita su propia revisión. Tampoco dice si es un módulo de venta o un Mercado: la administración podría registrar uno en el lugar del otro.
- Un módulo de venta retirado se puede volver a habilitar, y entonces sus drops abiertos vuelven a vender. Antes de retirar un módulo conviene cerrar sus drops.
- El contador de cambios de manos también cuenta un movimiento que deja el NFT en el mismo dueño.
- Un perdón de guarda con la fecha mal escrita no se puede deshacer, aunque desde la tercera revisión no puede pasar de dos años. El error siempre queda a favor de quien tiene la prenda. En el perdón para todas pesa más, porque alcanza también a las prendas que se vendan después: el panel de administración tiene que armar la fecha y mostrarla antes de firmar.
- Quien tenga la llave de pausa puede pausar una y otra vez. Si se pierde o la roban, la administración la quita.
- El número de pedido no prueba nada por sí solo: cualquiera puede copiar el de otra persona en su propia quema. El servidor tiene que comprobar a la vez el número, el NFT y la billetera que quemó.
- Si compra un contrato que después no puede operar, su NFT queda trabado. Es responsabilidad de ese comprador.
- La llave de administración también es la llave del stock sin vender: quien la tenga puede sumar un módulo de venta falso, crear NFT y reclamarlos.

Para tener en cuenta en la Etapa 2 (tarjeta): no hay forma de quitar un NFT después de un contracargo, y pagar la guarda con tarjeta implica que FGM la perdone en la cadena.

Pendientes que salieron al escribirlo:

- Fase 4: antes de despachar, el servidor tiene que comprobar que el NFT quemado nació de una venta oficial (el aviso de creación dice qué módulo lo creó), además de que la quema esté finalizada.
- Fase 4: el servidor une cada quema con su pedido comprobando a la vez el número de pedido, el NFT y la billetera. Una quema hecha por fuera del sitio llega sin número de pedido: tiene que poder completarse después, con la firma de esa billetera.
- Fase 4: el panel de administración arma las fechas de los perdones de guarda y muestra en claro qué se va a firmar.
- Antes de mainnet: la dirección de administración debería ser una billetera de varias firmas, y hay que vigilar los avisos de cambios de administración (tesorería, módulos de venta y Mercados nuevos).

## Cómo quedaron `Venta` y `Mercado`

`Venta` (la venta primaria):

- Un drop es una lista de prendas, cada una con su número, su precio y la huella de sus datos, más las fechas y las reglas de guarda. Una vez cargado no se puede cambiar.
- Un drop se puede cerrar en cualquier momento, antes o después de abrir. Lo cierran el operador o la administración. Lo que ya vendió queda vendido; lo que no vendió deja de estar en venta y puede ir a un drop nuevo, que espera la demora mínima como cualquier otro. Una prenda que vuelve a salir puede hacerlo con otro precio, otra guarda y otra huella, y con turnos anticipados nuevos.
- Comprar cobra y crea el NFT en la misma operación: el precio va directo de la billetera del comprador a la tesorería. Si algo falla, no pasa nada de las dos cosas.
- Quien compra dice el número del drop en el que vio la prenda y el precio que vio. Si la prenda ahora está en otro drop, la compra no se hace: así nadie compra con una guarda o unos datos distintos de los que tenía a la vista.
- Entrada anticipada: durante esa ventana compra solo quien esté en la foto, una prenda por billetera y por drop. Una compra que falla no gasta el turno.
- No tiene administración propia: sigue a la de `Prenda`, que solo nombra al operador. La tesorería, la moneda y la pausa son las de `Prenda`.
- El contrato rechaza un drop que abra antes de la demora mínima, precios por debajo del mínimo, guardas por encima del tope y números ya usados o que estén en otro drop.
- La demora mínima se fija al desplegar. El contrato no acepta menos de 24 horas, salvo en la testnet de Conflux eSpace y en la red simulada de las pruebas, donde se usa una corta para probar.
- Una prenda que este módulo vendió no puede volver a un drop, ni siquiera mientras se la está cobrando.

`Mercado` (la reventa):

- El NFT se queda en la billetera de su dueño hasta que se vende. El contrato nunca tiene plata ni NFT.
- Para publicar hay que haberle dado permiso al Mercado antes. Publicar de nuevo cambia la oferta. Una oferta dura como máximo 30 días.
- Al comprar se reparte el pago: 98% al vendedor y 2% a la tesorería. La comisión está escrita como constante y no hay nadie que administre el contrato: no se puede cambiar. Si un precio no da una comisión exacta, se redondea a favor del vendedor.
- Una oferta deja de valer si el NFT cambió de manos (aunque después vuelva al vendedor), si venció, si el vendedor la retira, si el vendedor le quitó al Mercado el permiso sobre todos sus NFT o si se le quitó al Mercado el permiso de ese NFT. Una oferta que dejó de valer no revive: hay que publicar de nuevo.
- Límite conocido: si el emisor de USDT0 bloqueara la dirección de `Venta` o de `Mercado`, ese módulo deja de poder cobrar. La salida es desplegar uno nuevo.
- Límite conocido: la pausa no detiene el reloj. Una pausa que cubra la ventana anticipada de un drop la consume, y las ofertas de reventa siguen venciendo.
- Límite conocido: el turno anticipado es una prenda por billetera y por drop. Si una colección se parte en varios drops, cada billetera de la foto tiene un turno en cada uno.
- Límite conocido: las fechas de un drop no tienen tope. Un drop con la fecha pública mal escrita queda abierto solo para la foto; se arregla cerrándolo y cargándolo de nuevo.

Cómo se probaron: tests de cada función con sus caminos de falla, un token de pago que bloquea cuentas, otro que responde "no" en vez de fallar y otro que le pasa el control al comprador, al vendedor y a la tesorería en medio de una compra, y secuencias al azar sobre los tres contratos juntos que siguen cada peso: qué tiene que tener cada billetera y qué tiene que haber recibido la tesorería. Además, en TypeScript: el recorrido completo (dos personas compran, se revenden un NFT, una reclama, se carga un drop nuevo, se cierra un drop abierto, y lo que no debe poder hacerse falla), una foto de saldos armada con la librería real de OpenZeppelin y el módulo de despliegue.

Los tres contratos también se rompieron a propósito, una regla por vez, con variantes propias y de los revisores. Con el código final, después de la cuarta revisión: 396 variantes (187 de `Prenda`, 119 de `Venta` y 90 de `Mercado`). Los tests detectan 394. Las dos que quedan no cambian nada: en `Mercado` se comprueba dos veces que el NFT siga en manos del vendedor, y sacar una de las dos comprobaciones da el mismo resultado; en `Venta`, leer los datos de la prenda después de cobrar en vez de antes da el mismo resultado mientras siga la otra protección (no volver a cargar una prenda vendida), y sacar las dos a la vez sí lo detectan los tests.

En total hay 378 tests: 362 en Solidity y 16 en TypeScript.

La corrida larga de tests (`--test-profile deep`), con muchos más casos al azar, también pasa.

El despliegue de los cuatro contratos (con el token de prueba) se probó en una red simulada.

### Segunda revisión independiente (26/11/2026)

La hizo otro revisor aparte, sobre `Venta`, `Mercado`, las correcciones de `Prenda` y los tres contratos juntos. No encontró fallas críticas ni altas, ni ninguna forma de robar o trabar plata o NFT. Encontró dos problemas medios y varios menores. No reemplaza a la auditoría externa.

Corregido:

- Medio: una oferta de reventa podía revivir. Si el vendedor le quitaba el permiso al Mercado creyendo que así retiraba la oferta, y semanas después se lo volvía a dar (por ejemplo, para vender otra prenda), la oferta vieja volvía a poder tomarse al precio viejo. Ahora quitarle un permiso al Mercado mata para siempre las ofertas hechas con ese permiso. Para eso `Prenda` lleva la cuenta de los permisos quitados (desde la tercera revisión, en dos cuentas: ver más abajo).
- Medio: un drop abierto no se podía frenar. Con la llave del operador robada, alguien podía cargar prendas reales al precio mínimo, con una ventana anticipada solo para sus billeteras, y si nadie lo notaba antes de abrir ya no había forma de pararlo. Ahora el operador y la administración pueden cerrar un drop en cualquier momento (era además la decisión 13 del dueño).
- Menor: la compra fijaba solo el precio. Ahora también nombra el drop.
- Menor: la duración máxima de una oferta se podía desplegar con cualquier valor. Ahora son 30 días fijos en el contrato.
- Menor: un Mercado apagado seguía figurando con el permiso de un NFT puntual. Ya no figura, y no acepta ofertas nuevas.
- El módulo de despliegue de prueba no estaba atado a una red de prueba. Ahora el token de prueba se niega a desplegarse fuera de la testnet de Conflux eSpace y de la red simulada (al principio solo se negaba a la mainnet; se ajustó después de la tercera revisión), y la mainnet se quitó de la configuración hasta que el dueño decida ir.
- Tests: el revisor mostró 19 cambios a `Venta` y `Mercado` que los tests no notaban. Se sumaron tests para todos. Las secuencias al azar ahora mueven NFT por un segundo Mercado, reutilizan números de prendas, dan y quitan permisos y llevan su propia cuenta de permisos y pausas. Las caminatas largas se partieron en varias cortas, porque una caminata larga que fallaba se quedaba sin memoria antes de decir qué había fallado.

Lo que la revisión señaló y no se cambió, con su motivo:

- Fechas de un drop sin tope: con el cierre de drops, una fecha mal escrita ya tiene arreglo. Queda como límite conocido.
- Demora mínima de apertura sin piso en el contrato: en testnet hace falta una demora corta. (Cambió después de la tercera revisión: el contrato ahora exige 24 horas fuera de la testnet.)
- Tamaño de un drop: cargar cada prenda cuesta gas. Según la estimación del revisor, unas 100 prendas rondan los 9,3 millones de gas en eSpace. El panel tiene que limitar cuántas prendas entran en un drop, y el número se mide en testnet.

Para la Fase 2 y la Fase 3 (sitio):

- El sitio tiene que mostrarle al vendedor qué ofertas suyas siguen valiendo. Propuesta a decidir en la Fase 3: una consulta en `Mercado` que diga si una oferta se puede tomar ahora.
- El servidor tiene que comparar cada drop nuevo con el catálogo, no solo mirar qué módulo creó el NFT: con la llave del operador robada, un drop falso sale del módulo oficial.
- El sitio no tiene que mostrar en venta una prenda cuyo número ya está usado (cuarta revisión).

Sin verificar todavía, porque hace falta la red real: el gas por transacción y las reglas de eSpace, y el comportamiento del USDT0 real.

### Tercera revisión independiente (27/11/2026)

La hizo un tercer revisor aparte, sobre todo lo que cambió después de las dos primeras: las cuatro protecciones de `Prenda`, la cuenta de permisos quitados, el cierre de drops y las demás correcciones. No encontró fallas críticas, altas ni medias. Encontró tres menores y varias observaciones. No reemplaza a la auditoría externa.

Corregido:

- Menor: si la tesorería y el operador fueran la misma cuenta, y si alguna vez USDT0 le pasara el control a quien recibe en medio de un pago, esa cuenta podía cerrar el drop durante la compra y cargar la misma prenda en un drop nuevo con otros datos. El comprador pagaba lo del drop que vio y el NFT salía con la huella de otro. Ahora `Venta` lee todo lo de la prenda antes de cobrar y no deja volver a cargar una prenda que ya vendió, ni siquiera mientras se la está cobrando. Hay un test que hace exactamente ese ataque.
- Menor: un perdón de guarda no tenía tope, y una fecha mal escrita no se puede deshacer. Ahora cada perdón llega como mucho a dos años desde que se da, y se puede renovar (a confirmar con el dueño).
- Menor: la demora mínima de apertura no tenía piso en el contrato. Ahora el contrato no acepta menos de 24 horas, salvo en la testnet de Conflux eSpace y en la red simulada de las pruebas.
- Observación: la cuenta de permisos quitados era una sola por dueño y Mercado, así que quitar el permiso de UN NFT mataba todas las ofertas de ese dueño. Ahora son dos cuentas: la del permiso general, que mata todas las ofertas del dueño en ese Mercado, y la de cada NFT, que mata solo la oferta de ese NFT.
- Observación: algunos textos decían más de lo que hace el código (que una tesorería mal escrita "nunca" recibe la plata, cómo se cuentan los permisos, las 24 horas). Corregidos aquí, en la arquitectura y en `SECURITY.md`.
- Observación: el aviso de creación de cada NFT (`Minted`) muestra la fecha de guarda gratis propia de la prenda, no la del perdón para todas; la que vale es la que devuelve `storageTermsOf`. Quedó escrito en el contrato. La forma de los avisos de creación y de reclamo, que va a leer el servidor, ahora está fijada por tests.
- Observación: el token de prueba solo se negaba a la mainnet de Conflux. Ahora solo acepta la testnet de Conflux eSpace y la red simulada, y hay un test de que el módulo de despliegue se frena en cualquier otra red sin crear nada.
- Tests: el revisor mostró 20 cambios al contrato que los tests no notaban. Se sumaron sus tests, adaptados a las dos cuentas, y otros propios. Las secuencias al azar ahora llevan su propia cuenta de fechas de guarda, cuotas y tesorería, en vez de leerlas del contrato, y prueban ofertas hechas con el permiso de un solo NFT.

Lo que la revisión señaló y no se cambió:

- Un módulo de venta retirado se puede volver a habilitar. Queda como decisión abierta antes de mainnet.
- Quien tenga la llave de pausa puede volver a pausar después de cada reanudación. Límite conocido: si pasa, la administración le quita la llave. Hay un test que lo deja escrito.

Las correcciones de esta revisión las revisó a su vez un cuarto revisor aparte.

### Cuarta revisión independiente (27/11/2026)

La hizo un cuarto revisor aparte, sobre las correcciones de la tercera revisión. No encontró fallas críticas, altas ni medias, ni ninguna forma de robar o trabar plata o NFT, de revivir una oferta, de que un tercero mate la oferta de otro, o de que un comprador reciba algo distinto de lo que tenía el drop que nombró. Revisó las cinco correcciones contra el código de OpenZeppelin y las dio por correctas. Encontró dos puntos menores, que son decisiones de diseño, y varias observaciones. No reemplaza a la auditoría externa.

Decisiones para el dueño, antes de mainnet (no frenan la testnet):

1. El tiempo gratis de un drop no tiene tope. El operador puede, por error de tipeo, dar 49 años de guarda gratis (180 días con dos ceros de más), más de lo que la administración podría dar con un perdón. Favorece a quien tiene la prenda y no se puede deshacer una vez vendida; se ataja mirando el drop en las 24 horas antes de que abra y cerrándolo. Opciones: un tope de tiempo gratis en `Venta` (es barato, porque `Venta` se puede reemplazar) o dejarlo como límite conocido. Hay un test que deja escrito cómo se comporta hoy.
2. Con el tope de dos años, el perdón para todas ya no es una salida permanente si USDT0 dejara de funcionar para `Prenda`: hay que renovarlo antes de que venza, y si se pierde la llave de administración los reclamos con guarda quedan frenados. Opciones: aceptarlo con un recordatorio fijo; sumar una salida permanente aparte, sin fecha (para que no se pueda tipear mal); o un tope más largo solo para el perdón para todas. Hay un test que deja escrito cómo se comporta hoy.

Observaciones:

- Un módulo de venta sabe lo que vendió él, pero no lo que vende otro. Con dos módulos de venta y una tesorería que opera los dos, la prenda que se está cobrando en uno puede aparecer en un drop del otro. Nadie la puede comprar ahí (la compra falla y el comprador no paga), pero queda figurando en venta. El sitio tiene que ocultar toda prenda cuyo número ya está usado. Hay un test.
- Que `Venta` lea los datos de la prenda antes de cobrar no se puede ver en ningún test, porque con la otra corrección (no volver a cargar una prenda vendida) ya nada los puede cambiar durante el cobro. Queda como doble protección.
- Qué error devuelve un perdón para una prenda cuya fecha propia ya está más allá del tope no estaba fijado por ningún test. Se sumó.
- Una oferta también cae si se quita un permiso con el que no se había hecho (por ejemplo, se da y se quita el permiso del NFT sobre una oferta hecha con el permiso general). Es a propósito y falla del lado seguro; el sitio tiene que mostrar qué ofertas siguen valiendo.
- Las secuencias al azar de los tres contratos no abren las transferencias ni apagan el Mercado. Se sumó un test que compara una oferta, paso a paso, contra un modelo simple, también con transferencias abiertas, permisos a billeteras, terceros y el Mercado apagado; corre 256 secuencias en la corrida normal y 2.000 en la larga.
- Textos desactualizados: corregidos.

El revisor hizo 21 variantes propias del código: los tests detectaron 19, una más con el test nuevo, y la que queda es la de leer los datos antes de cobrar (ver arriba).

## Tecnologías

- Contratos: Solidity 0.8.38 con OpenZeppelin Contracts 5.6.1. Compilador, objetivo de EVM (`cancun`) y optimizador fijos en `hardhat.config.ts`.
- Herramienta: Hardhat 3. Tests en Solidity (unitarios y con valores al azar) y, cuando haga falta, en TypeScript con viem. Despliegue con Ignition. Claves en el almacén cifrado de Hardhat (`hardhat-keystore`), fuera del repositorio.
- Sitio (Fase 2): Next.js con TypeScript en Vercel; billeteras con wagmi y viem.
- Datos (Fase 2): Postgres y almacenamiento de archivos; proveedor a elegir verificando antes su documentación.

## Datos técnicos verificados

Volver a verificar antes de usarlos. Fecha de la verificación entre paréntesis.

- Conflux eSpace es compatible con EVM y funciona con Hardhat, Foundry, ethers y viem (19/11/2026). https://doc.confluxnetwork.org/docs/espace/Overview
- Testnet: chain ID 71, RPC `https://evmtestnet.confluxrpc.com`, explorador https://evmtestnet.confluxscan.org. Mainnet: chain ID 1030, RPC `https://evm.confluxrpc.com` (19/11/2026). https://doc.confluxnetwork.org/docs/espace/network-endpoints
- Finalidad: la etiqueta `finalized` corresponde a bloques finalizados por la cadena PoS y tarda unas 400 confirmaciones (19/11/2026). https://doc.confluxnetwork.org/docs/espace/build/transaction
- Diferencias de eSpace con Ethereum que tocan a este proyecto (26/11/2026): el número de bloque no sirve para medir tiempo (los contratos usan la hora del bloque); guardar un dato nuevo cuesta 40.000 de gas, el doble que en Ethereum; de una transacción se devuelve como máximo un cuarto del gas límite, así que el sitio tiene que calcular el gas ajustado; las transacciones de eSpace entran solo en algunos bloques y comparten un cupo de gas, lo que limita cuántas prendas entran en un drop cargado en una sola transacción; acepta transacciones EIP-1559 y EIP-7702. https://doc.confluxnetwork.org/docs/espace/build/evm-compatibility
- La actualización v3.0 de Conflux incluyó CIP-645, que alinea eSpace con el EVM (MCOPY, almacenamiento transitorio), y CIP-7702 (26/11/2026). https://github.com/Conflux-Chain/conflux-rust/releases/tag/v3.0.0
- USDT0 en eSpace mainnet: `0xAf37E8B6c9ED7F6318979F56Fc287d76C30847FF`, 6 decimales, acepta pagos autorizados por firma (EIP-3009). La página no da direcciones de testnet (19/11/2026). https://doc.confluxnetwork.org/docs/espace/tutorials/x402/
- USDT0, según la auditoría de OpenZeppelin del 29/01/2025: actualizable (no dice quién controla las actualizaciones); su dueño puede bloquear cuentas y quemar los fondos de una cuenta bloqueada; una cuenta bloqueada puede recibir, pero no puede enviar ni ejecutar transferencias por cuenta de otros; el rol del puente puede quemar cualquier saldo. La auditoría cubre la versión de Arbitrum y el contrato pensado para cadenas nuevas, y no menciona a Conflux: confirmar contra el contrato real (releída el 26/11/2026). https://www.openzeppelin.com/news/usdt0-audit
- Verificación del código en ConfluxScan desde Hardhat: API de testnet `https://evmapi-testnet.confluxscan.org/api/` y de mainnet `https://evmapi.confluxscan.org/api/` (26/11/2026). https://doc.confluxnetwork.org/docs/espace/tutorials/VerifyContracts
- Solidity: se eligió la 0.8.38 (publicada el 22/10/2026) con pragma exacto; un repaso de seguridad del 06/11/2026 la da como la única versión sin errores conocidos (26/11/2026). https://guardian.security/blog/which-solidity-version-to-use/
- OpenZeppelin Contracts: la versión auditada que instala npm es la 5.6.1 (26/11/2026). https://docs.openzeppelin.com/contracts/5.x
- Librería `@openzeppelin/merkle-tree` 1.0.8, para armar la foto de saldos: las hojas llevan doble hash y van ordenadas, que es lo que espera `Venta`. Comprobado con un test que arma la foto con la librería y compra con sus pruebas (26/11/2026). https://github.com/OpenZeppelin/merkle-tree
- Hardhat 3 es estable; versión instalada 3.23.0; pide Node.js 22.13 o posterior (26/11/2026). https://hardhat.org/docs/getting-started

## Antes de mainnet

- Auditoría externa de los contratos. Punto central: que ningún Mercado pueda mover un NFT sin permiso de su dueño.
- Probar todo contra el USDT0 real en una copia de la red, incluido qué pasa si el emisor bloquea a un comprador, a la tesorería o a los contratos.
- Tomar las decisiones abiertas de la revisión independiente de `Prenda` y repasar con el dueño las que dicen "a confirmar", incluido el tope de dos años de cada perdón de guarda.
- Confirmar el objetivo de EVM con un despliegue de prueba en la testnet de eSpace.
- Escribir el módulo de despliegue de mainnet, con su propia llave: USDT0 real, administración aparte, demora de apertura de 24 horas (el contrato ya no acepta menos fuera de la testnet) y direcciones de tesorería, operador y pausa definidas.
- Vigilar los avisos de la cadena: drops nuevos (para compararlos con el catálogo), cambios de administración, de tesorería, de módulos y de Mercados. Con la llave de pausa a mano para frenar todo mientras la administración cierra un drop.
- Decidir si retirar un módulo de venta tiene que ser para siempre, como apagar un Mercado.
- Tomar las dos decisiones de la cuarta revisión: un tope de tiempo gratis por drop y una salida permanente si USDT0 dejara de funcionar.
- Revisión legal y contable del modelo, términos y condiciones y política de privacidad.

## Reglas técnicas de este proyecto

- Las claves privadas y frases semilla nunca van dentro del repositorio ni se le pasan al asistente.
- Compilador, objetivo de EVM y optimizador se fijan de forma explícita. Cambiarlos es un cambio de código y pide correr todos los tests.
- En testnet se usa `TestUSDT0`, que solo copia los 6 decimales de USDT0, no su comportamiento.
- Antes de usar una librería, un servicio o una dirección de contrato se verifica su documentación oficial vigente.

## Cómo levantar el proyecto

Hace falta Node.js 22.13 o posterior.

```bash
npm install
npx hardhat test
```

`npx hardhat build` compila los contratos y `npx tsc --noEmit` revisa los tipos. `npx hardhat test solidity --test-profile deep` es la corrida larga de tests, con muchos más casos al azar.

En una máquina con poca memoria (8 GB o menos) conviene correr los tests de Solidity de a un archivo, por ejemplo `npx hardhat test solidity contracts/Prenda.t.sol`: si una secuencia al azar falla, el informe de la falla puede ocupar mucha memoria.

Para probar el despliegue en una red simulada: `npx hardhat ignition deploy ignition/modules/Testnet.ts`. Ese módulo es solo para redes de prueba: despliega un token de prueba y deja a la cuenta que despliega como administración. La única red configurada es la testnet de Conflux eSpace (`--network confluxESpaceTestnet`).

Si la máquina no puede descargar el compilador de Solidity, se puede indicar uno local con la variable `ALLKA_SOLC_PATH` (binario nativo o `soljson.js` de la versión 0.8.38).

Para desplegar en la testnet de Conflux eSpace, paso a paso: [docs/DESPLIEGUE.md](docs/DESPLIEGUE.md). Después del despliegue, `npx hardhat ignition verify chain-71` publica el código en ConfluxScan y `npx hardhat run scripts/create-test-drop.ts --network confluxESpaceTestnet` carga un drop de prueba. Esos tres pasos todavía no se corrieron contra la testnet real.

## Próximos pasos

1. Despliegue en la testnet de Conflux eSpace, desde la computadora del dueño, siguiendo [docs/DESPLIEGUE.md](docs/DESPLIEGUE.md), y verificación en ConfluxScan. Después se anotan acá las cuatro direcciones.
2. Aprobación de la Fase 1 por el dueño.
