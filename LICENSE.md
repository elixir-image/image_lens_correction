                                 Apache License
                           Version 2.0, January 2004
                        http://www.apache.org/licenses/

   Copyright 2026 Kip Cole

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.

## Bundled lensfun calibration data

The Erlang term file `priv/lensfun/lensfun.etf` is generated from the
[lensfun](https://github.com/lensfun/lensfun) project's XML calibration
database. That database is distributed under the
[Creative Commons Attribution-ShareAlike 3.0 Unported License](https://creativecommons.org/licenses/by-sa/3.0/).

The lensfun reference C library is licensed under LGPL v3. This
package does not link to or distribute that library; it re-implements
the calibration math in Elixir.
