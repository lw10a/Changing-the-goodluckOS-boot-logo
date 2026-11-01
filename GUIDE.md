> [!CAUTION]
> # ⚠️ USE AT YOUR OWN RISK
>
> **This script writes directly to a raw SD card device. Choosing the wrong device can PERMANENTLY DESTROY DATA on your computer.**
>
> - Double-check the device name with `lsblk` before running it. Pass the **whole SD card** (e.g. `/dev/sdb`), never your system disk.
> - Back up your SD card (games, saves, settings) first.
> - This is an unofficial, community-made tool. It is **not affiliated with or endorsed by the goodluckOS project**.
> - Tested manually only on an R36S clone (GA36-MB v1.1) running goodluckOS. It may not work on other devices or card layouts.
> - The author takes **no responsibility** for damaged cards, lost data or bricked devices.
# Changing the goodluckOS boot logo

Answer to [goodluckOS issue #138](https://github.com/CodeZombie/goodluckOS/issues/138) ("Is it possible to change the default boot picture?").

Tested on an R36S clone (GA36-MB v1.1, Allwinner A23) running goodluckOS. Games and saves were untouched. No rebuild or reflash needed.

## How it works

The boot logo is `bootlogo.bmp` in a small **hidden FAT16 partition** near the start of the SD card (around the 36 MiB mark). It is not in the MBR partition table, so it never appears as `/dev/sdX3` and file managers can't see it. The trick is to find its byte offset and loop-mount it. `write-bootlogo.sh` does this for you.

## Image requirements

| Property | Value |
|---|---|
| Size | 640 x 480 |
| Color depth | 24-bit, no alpha |
| Compression | none |
| File size | exactly **921654 bytes** (54-byte header + 640x480x3) |

A 32-bit BMP (e.g. Paint's default or GIMP with alpha) comes out at 1,228,938 bytes and will not work.

## Step 1: Prepare the image

**Linux / ImageMagick** (recommended):

```bash
magick input.jpg -resize '640x480^' -gravity center -extent 640x480 \
  -type TrueColor -alpha off BMP3:bootlogo.bmp

# optional: match the stock header resolution fields (3780 px/m)
printf '\304\016\000\000\304\016\000\000' | dd of=bootlogo.bmp bs=1 seek=38 conv=notrunc

stat -c %s bootlogo.bmp    # must print 921654
```

**Windows / Paint**: resize to 640x480 (untick "maintain aspect ratio"), then *Save as -> BMP picture -> 24-bit Bitmap*. Check that the file properties say 921,654 bytes.

## Step 2: Write it to the card (script)

Insert the goodluckOS SD card into a Linux machine (a VM works if you pass the USB card reader through).

```bash
lsblk                       # identify the card, e.g. /dev/sdb (the whole disk, no number)
chmod +x write-bootlogo.sh
sudo ./write-bootlogo.sh /dev/sdb bootlogo.bmp
```

The script:

1. validates your BMP (640x480, 24-bit, 921654 bytes)
2. refuses partitions and disks holding your system, and asks for confirmation
3. backs up the first 128 MiB of the card and the original logo to `./bootlogo-backup-<timestamp>/`
4. locates the hidden FAT16 partition, swaps the file and verifies it with `cmp`

Then put the card in TF1 and boot.

**Double-check the device name.** Writing to the wrong disk can destroy data.

## Manual method (no script)

```bash
sudo umount /dev/sdX1 /dev/sdX2
sudo dd if=/dev/sdX of=first128.img bs=1M count=128        # backup + search copy

grep -obUaP "FAT16   " first128.img                          # prints byte positions
# offset = position - 54, and it must be a multiple of 512
# e.g. 37748790 - 54 = 37748736

mkdir -p fat16
sudo mount -o loop,ro,offset=37748736 first128.img fat16     # test on the copy first
ls -l fat16                                                  # should show bootlogo.bmp (921654 bytes)
sudo umount fat16

sudo mount -o loop,offset=37748736 /dev/sdX fat16            # now the real card
cp fat16/bootlogo.bmp ~/bootlogo.original.bmp
sudo cp bootlogo.bmp fat16/bootlogo.bmp
sync
cmp bootlogo.bmp fat16/bootlogo.bmp && echo SAME
sudo umount fat16 && sync
```

Ignore `grep` hits that aren't `(position - 54) % 512 == 0`; they are coincidental matches.

## Restore the stock logo

Run the script again with the saved original:

```bash
sudo ./write-bootlogo.sh /dev/sdX bootlogo-backup-<timestamp>/bootlogo.original.bmp
```

## Troubleshooting

- **Script says the file size is wrong**: the BMP is 32-bit or has a larger header. Re-export as 24-bit (see Step 1).
- **No FAT16 partition found**: your card may be a different layout. Nothing is written in that case; send the output of `sudo fdisk -l /dev/sdX`.
- **`mount: ... busy`**: make sure no terminal or file manager is open on the card, then run `sudo umount /dev/sdX?*`.
- **Console won't boot after a card change**: goodluckOS sometimes needs 2-3 power-on attempts.
- **Want it in the build instead**: replace `image/res/goodluck_bootlogo.bmp` before running `image/build.sh`; this requires building the whole image.
