# Desplegar en la testnet de Conflux eSpace

Guía paso a paso para poner los contratos de Allka Archivo en la red de prueba de Conflux eSpace desde una computadora con Windows. Lleva unos 20 minutos. Todo se hace con plata de prueba: no se gasta nada real.

"Desplegar" es publicar los contratos en la red para que cualquiera pueda usarlos. En la red de prueba se puede repetir las veces que haga falta.

## La regla más importante

En el paso 7 vas a usar la **clave privada** de una cuenta. Esa clave es la llave de la cuenta: quien la tiene, maneja la cuenta.

- Usá una cuenta nueva, creada solo para pruebas. Nunca la cuenta donde tenés fondos reales.
- La clave se escribe una sola vez, en tu computadora, cuando el programa la pide. Queda guardada cifrada, fuera de la carpeta del proyecto.
- No la pegues en un chat, en un mail ni en ningún archivo. Tampoco se la pases al asistente: no la necesita y no la tiene que ver.

## Paso 1. Abrir PowerShell

PowerShell es la ventana donde se escriben los comandos.

1. Apretá la tecla Windows (la del logo, abajo a la izquierda del teclado).
2. Escribí `PowerShell` y apretá Enter. Se abre una ventana oscura con un cursor que titila.

Cómo se usa: copiás un comando de esta guía, hacés clic derecho dentro de la ventana para pegarlo (o Ctrl+V) y apretás Enter. Esperá a que termine antes de pegar el siguiente: terminó cuando vuelve a aparecer el cursor al final de una línea que empieza con `PS`.

## Paso 2. Comprobar que están Node.js y Git

Pegá este comando:

```
node --version
```

Tiene que contestar `v22.13` o un número más alto. Si contesta un número más bajo, o dice que no reconoce `node`:

1. Abrí https://nodejs.org en el navegador.
2. Tocá el botón de descarga que dice **LTS**.
3. Abrí el archivo que se descargó y tocá **Next** (Siguiente) en cada pantalla hasta **Finish**.
4. Cerrá PowerShell y volvé a abrirlo (paso 1).

Ahora este:

```
git --version
```

Si dice que no reconoce `git`:

1. Abrí https://git-scm.com/download/win en el navegador. La descarga empieza sola.
2. Abrí el archivo que se descargó y tocá **Next** en cada pantalla hasta **Finish**.
3. Cerrá PowerShell y volvé a abrirlo.

## Paso 3. Bajar el proyecto

Pegá estos comandos de a uno. El primero te lleva al Escritorio; el segundo baja el proyecto a la carpeta `allka-archivo`; el último instala lo que el proyecto necesita y tarda uno o dos minutos.

```
cd $HOME\Desktop
```

```
git clone https://github.com/FGMLabs/allka-archivo.git
```

```
cd allka-archivo
```

```
git checkout fase-1/contratos
```

```
npm install
```

Notas:

- Si en el Escritorio ya hay una carpeta `allka-archivo` vacía, no hay problema: el proyecto se baja ahí. Si no está vacía, el segundo comando avisa que la carpeta ya existe: cambiale el nombre a la carpeta vieja y repetí el comando.
- El comando `git checkout fase-1/contratos` hace falta mientras la Fase 1 no esté aprobada. Después el código va a estar en la rama principal y ese paso se saltea.
- Cada vez que vuelvas a abrir PowerShell para seguir, entrá primero a la carpeta con `cd $HOME\Desktop\allka-archivo`.

## Paso 4 (opcional). Correr las pruebas

```
npx hardhat test
```

Tarda uno o dos minutos. Al final tiene que aparecer una línea con la cantidad de pruebas seguida de `passing`, y ninguna línea que diga `failing`.

## Paso 5. Crear una cuenta de prueba y agregar la red

En tu billetera (MetaMask, Fluent u otra compatible con Conflux eSpace), en el navegador de la computadora:

1. Creá una cuenta nueva. En MetaMask: tocá el nombre de la cuenta, arriba, y elegí la opción para agregar o crear una cuenta. Ponele un nombre que se distinga, por ejemplo `Allka pruebas`.
2. Agregá la red de prueba. La forma más simple: abrí https://chainlist.org/chain/71, tocá **Connect Wallet** y después el botón para agregar la red a la billetera. Si preferís cargarla a mano, estos son los datos:

| Dato | Valor |
|---|---|
| Nombre de la red | Conflux eSpace Testnet |
| URL de RPC | `https://evmtestnet.confluxrpc.com` |
| ID de cadena | `71` |
| Símbolo de la moneda | `CFX` |
| Explorador de bloques | `https://evmtestnet.confluxscan.org` |

3. Dejá la billetera con la cuenta de prueba y la red de prueba seleccionadas.

## Paso 6. Pedir CFX de prueba

El CFX de prueba paga el costo de publicar los contratos. Es gratis y no vale nada.

1. Abrí https://efaucet.confluxnetwork.org/ (la canilla oficial de la testnet de eSpace).
2. Conectá la billetera o pegá la dirección de la cuenta de prueba, según lo que pida la página, y tocá el botón para pedir CFX.
3. En unos segundos la cuenta de prueba tiene que mostrar un saldo de CFX.

## Paso 7. Guardar la clave de la cuenta de prueba en el almacén cifrado

Primero copiá la clave privada de la cuenta de prueba desde la billetera. En MetaMask: abrí el menú de la cuenta de prueba, entrá a los detalles de la cuenta y elegí mostrar la clave privada; pide la contraseña de MetaMask. Copiala.

Después, en PowerShell (dentro de la carpeta del proyecto):

```
npx hardhat keystore set DEPLOYER_PRIVATE_KEY
```

El programa pregunta, en inglés:

1. `This is the first time you are using the production keystore, please set a password.` Te pide inventar una contraseña para el almacén, de 8 caracteres o más. Anotala: la vas a usar cada vez que despliegues.
2. `Please confirm your password`. La misma contraseña otra vez.
3. `Enter secret to store in the production keystore`. Acá pegá la clave privada (clic derecho) y apretá Enter. No se ve nada mientras la pegás: es normal.

Listo: la clave quedó guardada cifrada en tu computadora, fuera de la carpeta del proyecto.

## Paso 8. Desplegar

```
npx hardhat ignition deploy ignition/modules/Testnet.ts --network confluxESpaceTestnet
```

El programa:

1. Pide la contraseña del almacén (`Enter the password`).
2. Pregunta `Confirm deploy to network confluxESpaceTestnet (71)?`. Escribí `y` y apretá Enter.
3. Publica los cuatro contratos, uno por uno. Tarda uno o dos minutos.

Al final dice `successfully deployed` y muestra cuatro direcciones, cada una con su nombre: `TestUSDT0`, `Prenda`, `Venta` y `Mercado`. Copiá esas líneas: son públicas y hay que anotarlas en `ESTADO.md`. También quedan guardadas en la carpeta `ignition\deployments\chain-71` del proyecto.

Qué se desplegó: un USDT0 de prueba que cualquiera puede fabricar, el contrato de las prendas, el de venta y el de reventa. La cuenta de prueba queda como administración, tesorería y operador. Los drops pueden abrir diez minutos después de cargados, en vez de 24 horas, para poder probar. El contrato de venta acepta esa demora corta solo en la testnet de Conflux eSpace; en cualquier otra red exige al menos 24 horas, y el USDT0 de prueba ni siquiera se puede desplegar fuera de la testnet.

## Paso 9. Publicar el código en el explorador

Así cualquiera puede leer el código de cada contrato al lado de su dirección.

```
npx hardhat ignition verify chain-71
```

Puede volver a pedir la contraseña del almacén.

## Paso 10. Cargar un drop de prueba

```
npx hardhat run scripts/create-test-drop.ts --network confluxESpaceTestnet
```

Pide la contraseña del almacén. Carga un drop con tres prendas de prueba (números 101, 102 y 103) a 5 USDT0 de prueba cada una. El programa dice a qué hora abre: unos doce minutos después.

## Paso 11. Mirarlo desde el celular

Abrí en el celular `https://evmtestnet.confluxscan.org/address/` seguido de la dirección de cada contrato. Por ejemplo, para el contrato de venta: `https://evmtestnet.confluxscan.org/address/0x...` con la dirección que salió al lado de `Venta`.

En cada página se ve el contrato, su código (si el paso 9 salió bien) y todo lo que pasó con él: el drop cargado aparece como una operación `createDrop` en el contrato de venta.

Comprar desde el explorador es posible pero incómodo: hay que fabricar USDT0 de prueba, autorizar el monto y comprar, escribiendo cada dato a mano. La forma cómoda de comprar desde el celular llega con el sitio, en la Fase 2.

## Si algo falla

- Copiá el texto del error (lo que aparece en rojo o después de la palabra `Error`) y pasáselo al equipo técnico. Nunca copies la clave privada ni la contraseña del almacén.
- `insufficient funds`: a la cuenta de prueba le falta CFX. Repetí el paso 6.
- Si PowerShell dice que `npx.ps1` o `npm.ps1` no se puede cargar porque la ejecución de scripts está deshabilitada: escribí `npx.cmd` en lugar de `npx`, y `npm.cmd` en lugar de `npm`, en los mismos comandos.
- Si el paso 8 se corta por la mitad, repetí el mismo comando: sigue desde donde quedó.
- Para empezar de cero con contratos nuevos, borrá la carpeta `ignition\deployments\chain-71` y repetí desde el paso 8.

## Lo que esta guía no cubre

- La mainnet. No está configurada a propósito: el despliegue real lleva otros valores, otra cuenta de administración y pasa antes por la auditoría externa.
- Los pasos 8 a 10 se probaron en una red simulada. Contra la testnet real se prueban por primera vez al seguir esta guía.
