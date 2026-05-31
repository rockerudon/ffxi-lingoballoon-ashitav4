# LingoBalloon (Ashita v4 Port)

This is an [Ashita v4](https://github.com/AshitaXI/Ashita-v4beta) port of the Balloon addon, forked from [StarlitGhost's version](https://github.com/StarlitGhost/Balloon).

The original Windower Balloon addon was created by Hando and modified by Kenshi, Yuki and Ghosty.

This Ashita v4 port was created by onimitch.

LingoBalloon is a translation-focused fork by rockmizx. Its translation behavior is based on ideas from [LingoXI](https://github.com/rockmizx/LingoXI), adapted so Balloon can translate NPC and story dialogue while keeping the cinematic dialogue window.

![Example default](https://github.com/onimitch/ffxi-balloon-ashitav4/blob/main/Example-default.png "Example default")

## How to install:
1. Download the latest Release from the [Releases page](https://github.com/rockmizx/ffxi-lingoballoon-ashitav4/releases)
2. Extract the **_lingoballoon_** folder to your **_Ashita4/addons_** folder

## How to enable it in-game:
1. Login to your character in FFXI
2. Type `/addon load lingoballoon`

## How to have Ashita load it automatically:
1. Go to your Ashita v4 folder
2. Open the file **_Ashita4/scripts/default.txt_**
3. Add `/addon load lingoballoon` to the list of addons to load under "Load Plugins and Addons"

## Commands

You can use `/lingoballoon`, `/lb` or `/lgb`

`/lingoballoon 0` - Hide balloon & display npc text in game log window.

`/lingoballoon 1` - Show balloon & hide npc text from game log window.

`/lingoballoon 2` - Show balloon & display npc text in game log window.

`/lingoballoon translate` - Toggle translation on or off.

`/lingoballoon lang <source> <target>` - Set translation source and target languages. Use `auto` as the source language for automatic detection.

`/lingoballoon source <source>` - Set only the source translation language.

`/lingoballoon target <target>` - Set only the target translation language.

`/lingoballoon interval <frames>` - Set how often the Copas translation loop runs. The default is 1 frame.

`/lingoballoon cache` - Show how many translations are currently cached.

`/lingoballoon cache clear` - Clear the translation cache.

`/lingoballoon reset` - Reset all settings back to default.

`/lingoballoon reset pos` - Reset the balloon position.

`/lingoballoon theme <theme>` - Switch theme (see below for info on Themes).

`/lingoballoon scale <scale>` - Scales the size of the balloon by a decimal (eg: 1.5).

`/lingoballoon delay <seconds>` - Delay before closing promptless balloons.

`/lingoballoon speed <chars per second>` - Speed that text is displayed, in characters per second. Set to 0 to disable.

`/lingoballoon portrait` - Toggle the display of character portraits, if the theme has settings for them.

`/lingoballoon move_close` - Toggle balloon auto-close on player movement.

`/lingoballoon always_on_top` - Toggle always on top (IMGUI mode). This mode renders the final elements using IMGUI to ensure Balloon always appears in front of any other custom UI. If for some reason you have issues with this mode, you can use this command to disable it.

`/lingoballoon in_combat` - Toggle displaying balloon during combat (off by default).

`/lingoballoon system` - Toggle displaying balloon for system messages, e.g Home Points. (on by default).

`/lingoballoon cinematic` - Toggle cinematic mode - auto hide game UI during cutscenes (on by default).

`/lingoballoon fps` - Toggle fps control during cutscenes to prevent lockups in certain cutscenes (on by default).

`/lingoballoon test <name> <lang> <mode>` - Display a test bubble. Lang: "-" (auto), "en" or "ja". Mode: 1 (dialogue), 2 (system).

`/lingoballoon test` - List all available tests.

## Translation

LingoBalloon translates the dialogue text shown in the Balloon window. It does not modify the original game data.

Translation requests are handled asynchronously using Copas/socket networking, following the same general non-blocking approach used by [LingoXI](https://github.com/rockmizx/LingoXI). This keeps the game from waiting on the translation request every frame.

While a new line is being translated, LingoBalloon shows a localized placeholder such as `Translating...`, `Traduzindo...` or `Traduciendo...`, depending on the selected target language. Once a line has been translated, it is saved to a local cache so repeated dialogue can appear immediately.

The default target language is Portuguese. You can change it with:

`/lingoballoon target en`

`/lingoballoon target es`

`/lingoballoon target ja`

You can also set both source and target languages at once:

`/lingoballoon lang auto pt`

`/lingoballoon lang en pt`

`/lingoballoon lang ja en`

## Cinematic mode

Balloon will auto hide the game UI during a cutscene and handle key/button presses to continue the dialogue.
If the game presents you with options during a cutscene, Balloon will temporarily re-show the game UI and hide it again once you've made a selection.

Cinematic mode is enabled by default. 
If you want to turn it off, you can toggle the option using `/lingoballoon cinematic`.

## Moving balloon

While the balloon is open you can use the mouse to click and drag it to move it around.

## Themes

There are currently four themes bundled with the addon.

### default

![Example default](https://github.com/onimitch/ffxi-balloon-ashitav4/blob/main/Example-default.png "Example default")

### ffvii-r

Requires "Libre Franklin Medium" or "Libre Franklin Regular" font, which you can get free from [Google Fonts](https://fonts.google.com/specimen/Libre+Franklin). Install the font in Windows.

![Example ffvii-r](https://github.com/onimitch/ffxi-balloon-ashitav4/blob/main/Example-ffvii-r.png "Example ffvii-r")

### ffxi

![Example ffxi](https://github.com/onimitch/ffxi-balloon-ashitav4/blob/main/Example-ffxi.png "Example ffxi")

### snes-ff

Uses "DotGothic16" font, which you can get free from [Google Fonts](https://fonts.google.com/specimen/DotGothic16). Install the font in Windows.

Alternatively it will look for "DePixel" font if "DotGothic16" not installed, which you can get free from [Be Fonts](https://befonts.com/depixel-font-family.html).

![Example snes-ff](https://github.com/onimitch/ffxi-balloon-ashitav4/blob/main/Example-snes-ff.png "Example snes-ff")

## Theme customisation

If you want to customise a theme, copy one of the existing themes from `addons/lingoballoon/themes` into `config/addons/lingoballoon/themes`.

Example: `config/addons/lingoballoon/themes/my_theme`.

In game switch to your new theme: `/lingoballoon theme my_theme`.

Edit the theme.xml file as you wish, or replace the pngs with alternatives. Sorry there isn't any more help on this for now but hopefully the existing themes are enough to figure out how it works.

Reload the theme by using: `/lingoballoon theme my_theme`.

See your changes immediately by using one of the test prompts:

e.g: `/lingoballoon test bahamut` or `/lingoballoon test colors`.


## Issues/Support

I only have limited time available to offer support, but if you have a problem, have discovered a bug or want to request a feature, please [create an issue on GitHub](https://github.com/rockmizx/ffxi-lingoballoon-ashitav4/issues).


## Gdifonts

This addon uses a custom fork of ThornyXI's gdifonts and gdifonttextures, in order to support colored regions and clipping:

https://github.com/onimitch/gdifonts/tree/regions

https://github.com/onimitch/gdifonttexture/tree/regions

## Support

If you find this project useful, you can support development here:

<a href="https://www.buymeacoffee.com/rockmizx" target="_blank"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me A Coffee" height="50" width="210"></a>

## Third-party libraries

LingoBalloon bundles the following third-party Lua libraries in `libs/` for its
asynchronous translation networking. All are distributed under the MIT license.
Their copyright notices are reproduced here to satisfy the license terms; the
original authors retain all rights.

- LuaSocket (`socket/`, `socket/url.lua`) - Copyright (c) Diego Nehab. MIT license.
- Copas (`copas.lua`) - Copyright (c) Kepler Project / Copas contributors. MIT license.
- coxpcall (`coxpcall.lua`) - Copyright (c) Kepler Project. MIT license.
- lua-binaryheap (`binaryheap.lua`) - Copyright (c) Thijs Schreijer. MIT license.
- lua-timerwheel (`timerwheel.lua`) - Copyright (c) Thijs Schreijer. MIT license.

Each library is licensed under the MIT license:

> Permission is hereby granted, free of charge, to any person obtaining a copy
> of this software and associated documentation files (the "Software"), to deal
> in the Software without restriction, including without limitation the rights
> to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
> copies of the Software, and to permit persons to whom the Software is
> furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in all
> copies or substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
> IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
> FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
> AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
> LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
> OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
> SOFTWARE.
