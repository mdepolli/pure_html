# Test Failures

**1 failure out of 1476 tests**

| File    | Failures |
| ------- | -------- |
| tests26 | 1        |

## Known Issues

### tests26 #2: nobr adoption agency in table

This test involves a complex interaction between foster parenting, adoption agency, and active formatting element reconstruction. The expected output shows two `<i>` elements from a single `<i>` start tag - one inside a foster-parented `<nobr>` and one as a sibling. This edge case requires further investigation.

Input: `<!DOCTYPE html><body><b><nobr>1<table><nobr></b><i><nobr>2<nobr></i>3`
