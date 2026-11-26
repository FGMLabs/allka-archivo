# Reglas de trabajo — Allka Archivo

Instrucciones para quien trabaje en este repositorio, sea una persona o un agente de IA. Al empezar cada sesión se leen este archivo, [ESTADO.md](ESTADO.md) y [docs/ARQUITECTURA.md](docs/ARQUITECTURA.md).

## Qué es

Una tienda de prendas de diseño únicas de allka. Cada prenda es un NFT en Conflux eSpace que da derecho a reclamar la prenda física. Tiene tres partes: venta primaria en USDT0, mercado de reventa dentro del mismo sitio y reclamo de la prenda. El diseño completo y las decisiones ya tomadas están en `docs/ARQUITECTURA.md` y en `ESTADO.md`.

## Quién decide

El dueño del producto aprueba cada fase. El equipo técnico cumple todos los roles: arquitectura, contratos (Solidity), sitio (front y back), pruebas y revisión de seguridad.

- Las decisiones se explican en simple, con ejemplos.
- Cuando al dueño le toca hacer un paso, se le indica dónde está cada página o botón.
- Las preguntas, pocas por vez y con opciones y una recomendación.

## Cómo se trabaja

- No se escribe código de una fase hasta que esté aprobada la anterior.
- Fases: contratos con sus tests → sitio con drops y compra en USDT0 → reventa → reclamo y panel de administración → revisión de seguridad y lista de control → auditoría externa → mainnet.
- Cada fase termina con algo que el dueño pueda probar desde el celular, la lista de lo que se probó y lo que quedó pendiente.

## Reglas

- Antes de usar una librería, un servicio o una dirección de contrato, verificar su documentación oficial vigente. No confiar en la memoria.
- Contratos simples, sobre librerías auditadas, con tests de todo camino por donde pase plata, incluidos los que deben fallar.
- No agregar funciones que nadie pidió: proponerlas y esperar el ok.
- Nunca pedir ni guardar claves privadas o frases semilla. Las carga el dueño en el almacén cifrado de Hardhat, fuera del repositorio.
- Antes de mostrar una parte, revisarla como tester y como revisor de seguridad; si se puede, con un agente aparte que no haya visto el código.
- Marcar con claridad lo que necesita abogado, contador o auditoría externa. No darlo por resuelto.
- No decir "listo" sin haberlo probado. Si algo falló o no se pudo probar, decirlo.
- Mantener `ESTADO.md` al día con decisiones, avance, pendientes y cómo levantar el proyecto.
- Todo en testnet hasta que el dueño diga lo contrario.

## El proyecto Hardhat

```
contracts/        Contratos en Solidity (*.sol) y sus tests unitarios (*.t.sol)
test/             Tests de integración en TypeScript
ignition/         Módulos de despliegue de Hardhat Ignition
docs/             Arquitectura en español y en inglés
hardhat.config.ts Compilador, objetivo de EVM y redes
```

- `npx hardhat build` compila, `npx hardhat test` corre todos los tests y `npx tsc --noEmit` revisa los tipos.
- Los tests unitarios van en Solidity, al lado del contrato. Los de TypeScript se reservan para recorridos completos.
- La versión del compilador, el objetivo de EVM y el optimizador están fijos en `hardhat.config.ts`. Cambiarlos es un cambio de código.
- Para escribir tests o tocar la configuración conviene cargar las guías de Hardhat que están en `.claude/skills/`.
- Documentación: Hardhat 3 en https://hardhat.org/llms.txt y viem en https://viem.sh/llms.txt

## Cuándo está terminada la versión 1

En testnet, desde el celular: dos personas compran con USDT0, se revenden un NFT entre ellas, una reclama la prenda, y se carga un drop nuevo sin tocar código. Además pasan los tests de lo que no debe poder hacerse.
